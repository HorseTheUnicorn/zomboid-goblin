-- Server authority for the client-rendered IsoSurvivor slice.
--
-- This is deliberately separate from NPCRegistry. NPCRegistry is the legacy
-- IsoZombie-backed engine and must not be allowed to create a donor body when
-- this mode is active. The server owns the actor's semantic position; clients
-- create only their local visual IsoSurvivor from the bounded snapshot.
local Config = require("GoblinSurvivor/Config")
local Profiles = require("GoblinSurvivor/Profiles")
local Protocol = require("GoblinSurvivor/ClientSurvivorProtocol")
local BaseManager = require("GoblinSurvivor/BaseManager")

local Server = {
    started = false,
    cleanedLegacyBodies = false,
    sequence = 0,
    lastBroadcastAt = 0,
    broadcastIntervalMs = 500,
    lastTickAt = 0,
    state = nil,
    states = {},
    rosterInitialized = false,
    speechSequence = 0,
    legacyCleanupScans = 0,
    lastLegacyCleanupAt = 0,
    lastPersistAt = 0,
    persistDirty = false,
    persistenceLoaded = false
}

local PERSISTENCE_NAME = "GoblinSurvivorClientSurvivor"
local PERSISTENCE_VERSION = 3
local PERSIST_INTERVAL_MS = 5000
local DEFAULT_JOB_BY_ROLE = {
    medic = "MEDIC",
    guard = "GUARD",
    hauler = "HAULER",
    farmer = "FARMER",
    builder = "BUILDER",
    scout = "SCOUT",
    mechanic = "DISASSEMBLE",
    companion = "SCAVENGE"
}
local WORK_OFFSETS = {
    -- Stations are deliberately several tiles apart.  The server authority
    -- also enforces MIN_BODY_SEPARATION, so close role offsets would make
    -- valid work assignments fight over the same destination.
    MEDIC = { x = -2.0, y = -2.0 },
    GUARD = { x = 2.0, y = -2.0 },
    HAULER = { x = -2.0, y = 2.0 },
    FARMER = { x = 2.0, y = 2.0 },
    BUILDER = { x = -2.0, y = 4.0 },
    SCOUT = { x = 2.0, y = 4.0 },
    DISASSEMBLE = { x = -4.0, y = 0.0 },
    LOOT = { x = 4.0, y = 0.0 },
    SCAVENGE = { x = 0.0, y = 4.0 }
}
-- Keep the complete default roster inside the normal camera area while
-- retaining a real gap between silhouettes. The Java authority repeats the
-- separation guard during movement and spawn, so this is only the semantic
-- starting layout sent to clients.
local FORMATION_OFFSETS = {
    { x = 7.00, y = 0.00 },
    { x = 5.36, y = 4.50 },
    { x = 1.22, y = 6.89 },
    { x = -3.50, y = 6.06 },
    { x = -6.58, y = 2.39 },
    { x = -6.58, y = -2.39 },
    { x = -3.50, y = -6.06 },
    { x = 1.22, y = -6.89 },
    { x = 5.36, y = -4.50 }
}
local ALLOWED_WORK_JOBS = {
    MEDIC = true,
    GUARD = true,
    HAULER = true,
    FARMER = true,
    BUILDER = true,
    SCOUT = true,
    LOOT = true,
    SCAVENGE = true,
    DISASSEMBLE = true
}
local persistentData
local restoreRecord

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] ClientSurvivorServer: " .. tostring(message))
    end
end

local function call(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then return false, nil end
    local ok, value = pcall(object[method], object, ...)
    return ok, value
end

local function position(object)
    if object == nil then return nil end
    local ok, x = call(object, "getX")
    local okY, y = call(object, "getY")
    local okZ, z = call(object, "getZ")
    if not ok or not okY or not okZ
        or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function onlinePlayers()
    local result = {}
    if type(getOnlinePlayers) ~= "function" then return result end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return result end
    local count = type(players.size) == "function" and players:size() or #players
    for index = 0, count - 1 do
        local player = type(players.get) == "function"
            and players:get(index) or players[index + 1]
        if player ~= nil then table.insert(result, player) end
    end
    return result
end

local function firstPlayer()
    return onlinePlayers()[1]
end

local function playerName(player)
    if player == nil or type(player.getUsername) ~= "function" then return nil end
    local ok, value = pcall(function() return player:getUsername() end)
    return ok and Protocol.safeText(value, 96, false) and value or nil
end

local function findPlayer(username)
    if type(username) ~= "string" or username == "" then return nil end
    local wanted = string.lower(username)
    for _, player in ipairs(onlinePlayers()) do
        local name = playerName(player)
        if name ~= nil and string.lower(name) == wanted then
            return player
        end
    end
    return nil
end

local function rosterIds()
    local result = { Config.npcId }
    if type(Profiles.managedIds) == "function" then
        for _, npcId in ipairs(Profiles.managedIds(Config.managedNpcCount)) do
            if npcId ~= Config.npcId then table.insert(result, npcId) end
        end
    end
    return result
end

local function profileFor(npcId)
    return Profiles.forId(npcId)
end

local function profileEnvelope(npcId)
    local profile = profileFor(npcId)
    return {
        sex = profile.sex,
        skinTone = profile.skinTone,
        hair = profile.hair,
        hairColor = profile.hairColor,
        beard = profile.beard,
        beardColor = profile.beardColor,
        -- The outfit is a deterministic randomized catalog choice.  Carry the
        -- concrete item ids in every snapshot so all clients render the same
        -- clothes instead of independently rolling different appearances.
        outfit = profile.outfit,
        walkSpeed = profile.walkSpeed,
        role = profile.role,
        survivor_type = profile.type,
        weapon = profile.weapon or "Base.AssaultRifle2",
        weapon_policy = profile.weapon_policy or "unlimited_ammo",
        combat_policy = profile.combat_policy or "hunt",
        god_mode = profile.god_mode ~= false
    }
end

local function defaultJob(profile)
    local role = type(profile) == "table" and string.upper(tostring(profile.role or "")) or ""
    return DEFAULT_JOB_BY_ROLE[string.lower(role)] or "SCAVENGE"
end

local function workOrigin(state)
    local base = BaseManager.point()
    if base ~= nil then return base end
    if state == nil or type(state.home_x) ~= "number"
        or type(state.home_y) ~= "number" or type(state.home_z) ~= "number" then
        return nil
    end
    return { x = state.home_x, y = state.home_y, z = state.home_z }
end

local function workPointFor(state, job)
    local origin = workOrigin(state)
    if origin == nil then return nil end
    local normalized = string.upper(tostring(job or state.job or "SCAVENGE"))
    local offset = WORK_OFFSETS[normalized] or WORK_OFFSETS.SCAVENGE
    return {
        x = origin.x + offset.x,
        y = origin.y + offset.y,
        z = origin.z
    }
end

local function initialPosition(player, rosterIndex)
    local point = position(player)
    if point == nil then return nil end
    rosterIndex = math.max(1, tonumber(rosterIndex) or 1)
    local offset = FORMATION_OFFSETS[rosterIndex]
    if offset == nil then
        local angle = (rosterIndex - 1) * (2 * math.pi / 9)
        offset = { x = math.cos(angle) * 7.0, y = math.sin(angle) * 7.0 }
    end
    -- These are visual actors, not PZ world objects, so no zombie-safe-square
    -- search is needed and no object is created beside the player on the
    -- server. Java enforces the same minimum during later movement.
    return {
        x = point.x + offset.x,
        y = point.y + offset.y,
        z = point.z
    }
end

local function ensureState(player)
    if Server.rosterInitialized and Server.state ~= nil then return Server.state end
    player = player or firstPlayer()
    local point = initialPosition(player, 1)
    if point == nil then return nil end
    Server.sequence = Server.sequence + 1
    local username = playerName(player)
    local data = persistentData()
    local savedRoster = data ~= nil and type(data.roster) == "table" and data.roster or {}
    local savedLayoutVersion = data ~= nil and tonumber(data.version) or 0
    local primary = nil
    for rosterIndex, npcId in ipairs(rosterIds()) do
        local actorPoint = initialPosition(player, rosterIndex)
        if actorPoint == nil then return nil end
        local profile = profileFor(npcId)
        local isGoblin = npcId == Config.npcId
        local job = isGoblin and nil or defaultJob(profile)
        local actorState = {
            protocol = Protocol.version,
            actor_id = npcId,
            entity_class = Protocol.entityClass,
            sequence = Server.sequence,
            x = actorPoint.x,
            y = actorPoint.y,
            z = actorPoint.z,
            display_name = profile.displayName,
            role = profile.role,
            survivor_type = profile.type,
            profile = profileEnvelope(npcId),
            -- BodyState uses the semantic mode while task carries the concrete
            -- deterministic goal. FOLLOW is a task, not a Python body mode.
            mode = isGoblin and "PARTY" or "WORK",
            task = isGoblin and "FOLLOW" or ("JOB_" .. job),
            target_username = isGoblin and username or nil,
            follow_username = isGoblin and username or nil,
            target_actor_id = nil,
            home_x = actorPoint.x,
            home_y = actorPoint.y,
            home_z = actorPoint.z,
            control_mode = isGoblin and "FOLLOW" or "JOB",
            combat_mode = "HUNT",
            job = job,
            work_status = isGoblin and "coordinating" or "assigned",
            work_count = 0,
            last_work_item = nil,
            manual_control = false,
            god_mode = true,
            alive = false,
            body_present = false,
            body_generation = 0,
            weapon_ready = false,
            firearm_type = profile.weapon,
            weapon_policy = profile.weapon_policy,
            shots_fired = 0,
            zombies_killed = 0,
            incoming_hits = 0,
            combat_status = "waiting_authority",
            server_timestamp_ms = Protocol.nowMs()
        }
        if not isGoblin then actorState.destination = workPointFor(actorState, job) end
        restoreRecord(actorState, savedRoster[npcId], player, savedLayoutVersion)
        Server.states[npcId] = actorState
        if npcId == Config.npcId then primary = actorState end
    end
    Server.state = primary
    Server.rosterInitialized = primary ~= nil
    Server.persistenceLoaded = true
    if not Server.rosterInitialized then return nil end
    log("authoritative client-survivor actor initialized at "
        .. tostring(primary.x) .. "," .. tostring(primary.y) .. "," .. tostring(primary.z)
        .. " (" .. tostring(#rosterIds()) .. " actor(s))")
    return Server.state
end

local function moveToward(state, target, stopDistance)
    local step = rawget(_G, "stepGoblinServerActor")
    if type(step) ~= "function" then
        if not Server.authorityMissingLogged then
            Server.authorityMissingLogged = true
            log("Java human authority unavailable; launch local server with -Storm")
        end
        return false
    end
    local ok, ready = pcall(step, state, target, stopDistance or 0)
    if not ok and not Server.authorityErrorLogged then
        Server.authorityErrorLogged = true
        log("Java authority step failed: " .. tostring(ready))
    end
    return ok and ready == true
end

local function publicState(state)
    state = state or Server.state
    if state == nil or state.authority ~= "java_human" then return nil end
    return {
        protocol = state.protocol,
        actor_id = state.actor_id,
        entity_class = state.entity_class,
        sequence = state.sequence,
        x = state.x,
        y = state.y,
        z = state.z,
        display_name = state.display_name,
        role = state.role,
        survivor_type = state.survivor_type,
        profile = state.profile,
        authority = state.authority,
        movement_blocked = state.movement_blocked == true,
        navigation_status = state.navigation_status,
        route_remaining = state.route_remaining,
        mode = state.mode,
        task = state.task,
        target_username = state.target_username,
        target_actor_id = state.target_actor_id,
        control_mode = state.control_mode,
        job = state.job,
        work_status = state.work_status,
        work_count = state.work_count or 0,
        last_work_item = state.last_work_item,
        alive = state.alive == true,
        body_present = state.body_present == true,
        body_generation = state.body_generation or 0,
        health = state.health or 0,
        weapon_ready = state.weapon_ready == true,
        firearm_type = state.firearm_type,
        weapon_policy = state.weapon_policy,
        god_mode = state.god_mode == true,
        combat_mode = state.combat_mode,
        combat_status = state.combat_status,
        combat_target_id = state.combat_target_id,
        shots_fired = state.shots_fired or 0,
        zombies_killed = state.zombies_killed or 0,
        incoming_hits = state.incoming_hits or 0,
        last_kill_id = state.last_kill_id,
        death_reason = state.death_reason,
        last_fire_error = state.last_fire_error,
        spawn_status = state.spawn_status,
        spawn_pending = state.spawn_pending == true,
        spawn_attempts = state.spawn_attempts or 0,
        server_timestamp_ms = state.server_timestamp_ms
    }
end

local function statePoint(state)
    state = state or Server.state
    if state == nil then return nil end
    return { x = state.x, y = state.y, z = state.z }
end

local function orderedStates()
    local result = {}
    for _, npcId in ipairs(rosterIds()) do
        local state = Server.states[npcId]
        if state ~= nil then table.insert(result, state) end
    end
    return result
end

persistentData = function()
    if type(ModData) ~= "table" or type(ModData.getOrCreate) ~= "function" then
        return nil
    end
    local ok, data = pcall(ModData.getOrCreate, PERSISTENCE_NAME)
    return ok and type(data) == "table" and data or nil
end

local function savedNumber(value)
    return type(value) == "number"
        and value == value and value ~= math.huge and value ~= -math.huge
        and value or nil
end

local function savedText(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and value or nil
end

local function savedPoint(record, prefix)
    if type(record) ~= "table" then return nil end
    local x = savedNumber(record[prefix .. "_x"])
    local y = savedNumber(record[prefix .. "_y"])
    local z = savedNumber(record[prefix .. "_z"])
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function setSavedPoint(record, prefix, point)
    if type(point) ~= "table" then return end
    if savedNumber(point.x) ~= nil then record[prefix .. "_x"] = point.x end
    if savedNumber(point.y) ~= nil then record[prefix .. "_y"] = point.y end
    if savedNumber(point.z) ~= nil then record[prefix .. "_z"] = point.z end
end

local function markPersistentDirty()
    Server.persistDirty = true
end

restoreRecord = function(state, record, player, savedLayoutVersion)
    if type(record) ~= "table" then return end
    -- Versions 1 and 2 stored cramped or camera-wide formation geometry. Keep
    -- their task and job choices, but rebuild position/home/destination from
    -- the compact separated layout once; the next save writes version 3.
    if (tonumber(savedLayoutVersion) or 0) >= 3 then
        local point = savedPoint(record, "position")
        if point ~= nil then
            state.x, state.y, state.z = point.x, point.y, point.z
        end
        local home = savedPoint(record, "home")
        if home ~= nil then
            state.home_x, state.home_y, state.home_z = home.x, home.y, home.z
        end
        local hold = savedPoint(record, "hold")
        if hold ~= nil then
            state.hold_x, state.hold_y, state.hold_z = hold.x, hold.y, hold.z
        end
        local destination = savedPoint(record, "destination")
        if destination ~= nil then state.destination = destination end
    end
    state.body_generation = math.max(0, math.floor(savedNumber(record.body_generation) or 0))
    state.task = savedText(record.task, 64) or state.task
    state.mode = savedText(record.mode, 32) or state.mode
    state.control_mode = savedText(record.control_mode, 32) or state.control_mode
    state.combat_mode = savedText(record.combat_mode, 32) or state.combat_mode
    state.job = savedText(record.job, 32)
    if state.actor_id ~= Config.npcId and state.job == nil then
        state.job = defaultJob({ role = state.role })
    end
    state.arrival_task = savedText(record.arrival_task, 64)
    state.target_actor_id = savedText(record.target_actor_id, 96)
    state.target_username = savedText(record.target_username, 96)
    state.follow_username = savedText(record.follow_username, 96)
    state.manual_control = record.manual_control == true
    state.work_status = savedText(record.work_status, 64) or state.work_status
    state.work_count = math.max(0, math.floor(savedNumber(record.work_count) or state.work_count or 0))
    state.last_work_item = savedText(record.last_work_item, 96)
    -- A saved follow target is useful only when it is still online. On a
    -- server restart, bind the roster back to the first online player instead
    -- of leaving every actor permanently holding on a stale username.
    if state.control_mode == "FOLLOW" then
        local wanted = state.follow_username or state.target_username
        if findPlayer(wanted) == nil then
            local name = playerName(player)
            state.follow_username = name
            state.target_username = name
        end
    end
    -- Older saves initialized every companion as a player follower. Migrate
    -- only records that were never explicitly controlled; a later FOLLOW or
    -- JOIN_PARTY command remains a deliberate player choice.
    if state.actor_id ~= Config.npcId and state.manual_control ~= true then
        state.control_mode = "JOB"
        state.mode = "WORK"
        state.job = state.job or defaultJob({ role = state.role })
        state.task = "JOB_" .. state.job
        state.target_username = nil
        state.follow_username = nil
        state.target_actor_id = nil
        state.arrival_task = nil
        state.combat_mode = "HUNT"
        state.destination = workPointFor(state, state.job)
        state.work_status = "assigned"
    end
end

local function savePersistentRoster(force)
    local now = Protocol.nowMs()
    if not force and (not Server.persistDirty
        or (Server.lastPersistAt > 0 and now - Server.lastPersistAt < PERSIST_INTERVAL_MS)) then
        return true
    end
    local data = persistentData()
    if data == nil then return false end
    data.version = PERSISTENCE_VERSION
    data.roster = {}
    for _, state in ipairs(orderedStates()) do
        local record = {
            actor_id = state.actor_id,
            body_generation = state.body_generation or 0,
            task = state.task,
            mode = state.mode,
            control_mode = state.control_mode,
            combat_mode = state.combat_mode,
            job = state.job,
            arrival_task = state.arrival_task,
            target_actor_id = state.target_actor_id,
            target_username = state.target_username,
            follow_username = state.follow_username,
            manual_control = state.manual_control == true,
            work_status = state.work_status,
            work_count = state.work_count or 0,
            last_work_item = state.last_work_item
        }
        setSavedPoint(record, "position", state)
        setSavedPoint(record, "home", {
            x = state.home_x, y = state.home_y, z = state.home_z
        })
        setSavedPoint(record, "hold", {
            x = state.hold_x, y = state.hold_y, z = state.hold_z
        })
        setSavedPoint(record, "destination", state.destination)
        data.roster[state.actor_id] = record
    end
    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, PERSISTENCE_NAME)
    end
    Server.lastPersistAt = now
    Server.persistDirty = false
    return true
end

local function targetInfo(message)
    local target = type(message) == "table" and message.target or nil
    if type(target) ~= "table" then return nil, nil end
    local kind = string.lower(tostring(target.kind or ""))
    local label = target.name or target.label or target.player
    return kind, label
end

local function resolvePoint(message, actorState)
    local kind, label = targetInfo(message)
    if kind == "player" then
        local player = findPlayer(label)
        if player == nil then return nil, "target player is not online" end
        local point = position(player)
        if point == nil then return nil, "target player has no world position" end
        return point, nil
    end
    if kind == "current_position" then
        return statePoint(actorState), nil
    end
    if kind == "goblin" then
        return statePoint(Server.states[Config.npcId] or Server.state), nil
    end
    if kind == "home_base" or kind == "base" then
        local base = BaseManager.point()
        if base ~= nil then return base, nil end
        local state = actorState or Server.state
        local fallback = workOrigin(state)
        if fallback == nil then return nil, "home base has not been anchored" end
        return fallback, nil
    end
    if kind == "area" or kind == "named_location" then
        local normalized = string.lower(tostring(label or ""))
        if normalized == "home base" or normalized == "base" then
            local base = BaseManager.point()
            if base ~= nil then return base, nil end
            local state = actorState or Server.state
            local fallback = workOrigin(state)
            if fallback == nil then return nil, "home base has not been anchored" end
            return fallback, nil
        end
        return nil, "named client-survivor locations require a server anchor"
    end
    if kind == "" then return nil, "command target is missing" end
    return nil, "target kind '" .. kind .. "' has no deterministic client-survivor resolver"
end

local function setHold(state, task, mode, point)
    if state == nil or point == nil then return false end
    state.control_mode = "HOLD"
    state.task = task or "HOLD"
    state.mode = mode or "PARTY"
    state.target_username = nil
    state.follow_username = nil
    state.target_actor_id = nil
    state.destination = nil
    state.arrival_task = nil
    state.combat_mode = "HUNT"
    state.manual_control = true
    state.work_status = "paused"
    state.hold_x = point.x
    state.hold_y = point.y
    state.hold_z = point.z
    return true
end

local function setDestination(state, task, mode, point, arrivalTask)
    if state == nil or point == nil then return false end
    state.control_mode = "MOVE"
    state.task = task or "MOVE_TO"
    state.mode = mode or "PARTY"
    state.target_username = nil
    state.follow_username = nil
    state.target_actor_id = nil
    state.destination = { x = point.x, y = point.y, z = point.z }
    state.arrival_task = arrivalTask
    state.combat_mode = "HUNT"
    state.manual_control = true
    state.work_status = "moving"
    return true
end

local function setFollow(state, task, player)
    local name = playerName(player)
    if state == nil or name == nil then return false end
    state.control_mode = "FOLLOW"
    state.task = task or "FOLLOW"
    state.mode = "PARTY"
    state.target_username = name
    state.follow_username = name
    state.target_actor_id = nil
    state.destination = nil
    state.arrival_task = nil
    state.combat_mode = "HUNT"
    state.manual_control = true
    state.work_status = "following"
    return true
end

local function setFollowActor(state, task, targetState)
    if state == nil or targetState == nil or state == targetState then return false end
    state.control_mode = "FOLLOW_ACTOR"
    state.task = task or "FOLLOW_GOBLIN"
    state.mode = "PARTY"
    state.target_username = nil
    state.follow_username = nil
    state.target_actor_id = targetState.actor_id
    state.destination = nil
    state.arrival_task = nil
    state.combat_mode = "HUNT"
    state.manual_control = true
    state.work_status = "squad_follow"
    return true
end

local function updateTask(state)
    if state == nil then return false end
    local target = nil
    if state.control_mode == "COMBAT" then
        -- Java scans and selects ordinary hostile zombies.  A combat command
        -- must not silently turn back into follow movement while no target is
        -- loaded in the current cell.
        target = nil
    elseif state.control_mode == "FOLLOW" then
        local player = findPlayer(state.follow_username or state.target_username)
        if player ~= nil then
            target = position(player)
            state.target_username = playerName(player)
        else
            -- A disconnected follow target must not silently retarget the
            -- actor to an arbitrary player. Hold until a new command arrives.
            state.control_mode = "HOLD"
            state.task = "HOLD"
            state.target_username = nil
        end
    elseif state.control_mode == "FOLLOW_ACTOR" then
        local targetState = Server.states[state.target_actor_id]
        if targetState ~= nil then
            target = statePoint(targetState)
        else
            state.control_mode = "HOLD"
            state.task = "HOLD"
            state.target_actor_id = nil
        end
    elseif state.control_mode == "MOVE" then
        target = state.destination
    elseif state.control_mode == "JOB" then
        state.destination = state.destination or workPointFor(state, state.job)
        target = state.destination
    end
    if target ~= nil then
        local moved = moveToward(state, target,
            (state.control_mode == "FOLLOW" or state.control_mode == "FOLLOW_ACTOR")
                and 3.0 or 0.75)
        if not moved then return false end
        if state.control_mode == "MOVE" then
            local dx = target.x - state.x
            local dy = target.y - state.y
            if math.sqrt(dx * dx + dy * dy) <= 0.8 then
                state.destination = nil
                state.control_mode = "HOLD"
                local arrivalTask = state.arrival_task
                state.arrival_task = nil
                state.task = arrivalTask or "HOLD"
                state.hold_x = state.x
                state.hold_y = state.y
                state.hold_z = state.z
            end
        elseif state.control_mode == "JOB" then
            local dx = target.x - state.x
            local dy = target.y - state.y
            if math.sqrt(dx * dx + dy * dy) <= 0.8 then
                state.work_status = "working"
                state.task = "JOB_" .. tostring(state.job or "SCAVENGE")
            end
        end
    else
        if not moveToward(state, nil, 0) then return false end
    end
    state.server_timestamp_ms = Protocol.nowMs()
    markPersistentDirty()
    return true
end

local function isLegacyBody(body)
    if body == nil or type(body.getModData) ~= "function" then return false end
    local ok, data = pcall(function() return body:getModData() end)
    if not ok or type(data) ~= "table" then return false end
    -- Only remove an unmistakably old Goblin-owned donor.  In particular,
    -- never treat a generic friendly-survivor flag as ownership: population
    -- zombies and other mods must remain under the vanilla population manager.
    local nativeDonor = data.goblin_engine == "native"
        and data.goblin_npc_id == Config.npcId
        and data.goblin_owned == true
        and data.goblin_body_class == "IsoZombie"
    local legacyDonor = data.GoblinSurvivorNPC == true
        and data.GoblinSurvivorID == Config.npcId
        and data.GoblinSurvivorOwned == true
    return nativeDonor or legacyDonor
end

function Server.ordinaryZombieCount()
    if type(getCell) ~= "function" then return 0 end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil or type(cell.getZombieList) ~= "function" then return 0 end
    local okList, zombies = pcall(function() return cell:getZombieList() end)
    if not okList or zombies == nil then return 0 end
    local count = type(zombies.size) == "function" and zombies:size() or #zombies
    local ordinary = 0
    for index = 0, count - 1 do
        local body = type(zombies.get) == "function"
            and zombies:get(index) or zombies[index + 1]
        if body ~= nil and not isLegacyBody(body) then ordinary = ordinary + 1 end
    end
    return ordinary
end

local function cleanupLegacyBodies()
    if Server.cleanedLegacyBodies or type(getCell) ~= "function" then return end
    if Server.legacyCleanupScans >= 10 then
        Server.cleanedLegacyBodies = true
        return
    end
    local now = Protocol.nowMs()
    if Server.lastLegacyCleanupAt > 0
        and now - Server.lastLegacyCleanupAt < 1000 then
        return
    end
    Server.lastLegacyCleanupAt = now
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil or type(cell.getZombieList) ~= "function" then return end
    local okList, zombies = pcall(function() return cell:getZombieList() end)
    if not okList or zombies == nil then return end
    local count = type(zombies.size) == "function" and zombies:size() or #zombies
    Server.legacyCleanupScans = Server.legacyCleanupScans + 1
    local removed = 0
    for index = count - 1, 0, -1 do
        local body = type(zombies.get) == "function"
            and zombies:get(index) or zombies[index + 1]
        if isLegacyBody(body) then
            call(body, "removeFromWorld")
            removed = removed + 1
        end
    end
    if removed > 0 then
        log("removed " .. tostring(removed)
            .. " legacy IsoZombie Goblin body/bodies")
    elseif Server.legacyCleanupScans == 1 then
        log("legacy cleanup scanned " .. tostring(count)
            .. " loaded zombie(s); no marked Goblin zombie body found")
    end
    if Server.legacyCleanupScans >= 10 then Server.cleanedLegacyBodies = true end
end

function Server.snapshot()
    return publicState()
end

function Server.ensureForPlayer(player)
    return ensureState(player) ~= nil
end

function Server.rosterIds()
    local result = {}
    for _, npcId in ipairs(rosterIds()) do result[#result + 1] = npcId end
    return result
end

function Server.snapshotAll()
    local result = {}
    for _, state in ipairs(orderedStates()) do
        table.insert(result, publicState(state))
    end
    return result
end

function Server.isKnownNpcId(npcId)
    if type(npcId) ~= "string" then return false end
    for _, candidate in ipairs(rosterIds()) do
        if candidate == npcId then return true end
    end
    return false
end

function Server.status()
    local ready = Server.state ~= nil and Server.state.authority == "java_human"
    local present = ready and Server.state.body_present == true
    return {
        npc_id = Config.npcId,
        name = Config.npcName,
        alive = present,
        body_present = present,
        active = true,
        control_ready = present,
        npc_engine_ready = present,
        body_mode = "client_survivor",
        authority = ready and Server.state.authority or nil,
        movement_blocked = ready and Server.state.movement_blocked == true,
        navigation_status = ready and Server.state.navigation_status or "waiting_authority",
        route_remaining = ready and Server.state.route_remaining or 0,
        role = ready and Server.state.role or Config.npcRole,
        mode = ready and Server.state.mode or "WAITING",
        task = ready and Server.state.task or nil,
        target_player = ready and Server.state.target_username or nil,
        target_npc_id = ready and Server.state.target_actor_id or nil,
        control_mode = ready and Server.state.control_mode or "WAITING",
        job = ready and Server.state.job or nil,
        work_status = ready and Server.state.work_status or "waiting_authority",
        work_count = ready and Server.state.work_count or 0,
        last_work_item = ready and Server.state.last_work_item or nil,
        body_generation = ready and Server.state.body_generation or 0,
        health = ready and Server.state.health or 0,
        weapon_ready = ready and Server.state.weapon_ready == true,
        firearm_type = ready and Server.state.firearm_type or "Base.AssaultRifle2",
        weapon_policy = ready and Server.state.weapon_policy or "unlimited_ammo",
        god_mode = ready and Server.state.god_mode == true or true,
        hostile_to_zombies = ready and Server.state.hostile_to_zombies == true or true,
        combat_mode = ready and Server.state.combat_mode or "DEFEND",
        combat_status = ready and Server.state.combat_status or "waiting_authority",
        combat_target_id = ready and Server.state.combat_target_id or nil,
        shots_fired = ready and Server.state.shots_fired or 0,
        zombies_killed = ready and Server.state.zombies_killed or 0,
        incoming_hits = ready and Server.state.incoming_hits or 0,
        last_kill_id = ready and Server.state.last_kill_id or nil,
        death_reason = ready and Server.state.death_reason or nil,
        friendly = true,
        protected = Config.protected == true,
        needs_disabled = true,
        spawn_status = ready and (Server.state.spawn_status or "waiting_authority") or "waiting_anchor",
        spawn_pending = not present,
        spawn_attempts = ready and Server.state.spawn_attempts or 0
    }
end

function Server.statusAll()
    local result = {}
    for _, state in ipairs(orderedStates()) do
        table.insert(result, {
            npc_id = state.actor_id,
            name = state.display_name,
            alive = state.authority == "java_human" and state.body_present == true,
            body_present = state.body_present == true,
            active = true,
            control_ready = state.authority == "java_human" and state.body_present == true,
            npc_engine_ready = state.authority == "java_human",
            body_mode = "client_survivor",
            role = state.role,
            mode = state.mode,
            task = state.task,
            target_player = state.target_username,
            target_npc_id = state.target_actor_id,
            control_mode = state.control_mode,
            job = state.job,
            work_status = state.work_status,
            work_count = state.work_count or 0,
            last_work_item = state.last_work_item,
            friendly = true,
            protected = state.actor_id == Config.npcId and Config.protected == true,
            needs_disabled = state.actor_id == Config.npcId,
            body_generation = state.body_generation or 0,
            health = state.health or 0,
            weapon_ready = state.weapon_ready == true,
            firearm_type = state.firearm_type
                or "Base.AssaultRifle2",
            weapon_policy = state.weapon_policy
                or "unlimited_ammo",
            god_mode = state.god_mode == true,
            hostile_to_zombies = state.hostile_to_zombies == true,
            combat_mode = state.combat_mode,
            combat_status = state.combat_status,
            combat_target_id = state.combat_target_id,
            shots_fired = state.shots_fired or 0,
            zombies_killed = state.zombies_killed or 0,
            incoming_hits = state.incoming_hits or 0,
            last_kill_id = state.last_kill_id,
            death_reason = state.death_reason,
            spawn_status = state.authority == "java_human"
                and (state.spawn_status or "present") or "waiting_authority",
            spawn_pending = state.body_present ~= true,
            spawn_attempts = state.spawn_attempts or 0
        })
    end
    return result
end

function Server.start()
    if Server.started then return true end
    if Events == nil or Events.OnClientCommand == nil
        or type(Events.OnClientCommand.Add) ~= "function" then
        log("OnClientCommand is unavailable; client actor requests disabled")
        return false
    end
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= Protocol.module or command ~= Protocol.requestCommand then return end
        if type(args) ~= "table" or args.protocol ~= Protocol.version then return end
        local state = ensureState(player)
        if state ~= nil and type(sendServerCommand) == "function" then
            for _, actorState in ipairs(orderedStates()) do
                pcall(sendServerCommand, player, Protocol.module,
                    Protocol.stateCommand, publicState(actorState))
            end
        end
    end)
    Server.started = true
    log("client-survivor authority ready")
    return true
end

function Server.tick()
    if Config.bodyMode ~= "client_survivor" then return false end
    local players = onlinePlayers()
    local player = players[1]
    local state = ensureState(player)
    if state == nil then return false end
    -- Keep semantic roster state and saved job assignments alive after the
    -- last player disconnects, but do not ask Java to materialize or route
    -- physical bodies without a loaded player/world anchor. Dedicated PZ
    -- servers can unload the current cell immediately after the last client
    -- leaves; repeatedly calling the authority in that window only produces
    -- futile spawn/rebind attempts and noisy route diagnostics. The next
    -- connected player resumes physical servicing from the saved state.
    if #players == 0 then
        cleanupLegacyBodies()
        savePersistentRoster(false)
        Server.lastTickAt = Protocol.nowMs()
        return true
    end
    -- Only Goblin's automatic FOLLOW target is rebound when a player returns.
    -- A deliberate manual command remains in force. This does not invent a
    -- fake player or use a zombie fallback.
    local goblin = Server.states[Config.npcId]
    if goblin ~= nil and goblin.manual_control ~= true
        and goblin.control_mode == "HOLD" then
        setFollow(goblin, "FOLLOW", player)
    end
    -- Run this after the authority has a usable world cell. On a fresh server
    -- tick the cell can exist before the player/world position is available,
    -- so the one-shot cleanup would otherwise miss a legacy IsoZombie
    -- persisted by a previous native-body test and leave it beside the spawn
    -- point.
    cleanupLegacyBodies()
    for _, actorState in ipairs(orderedStates()) do
        if actorState.control_mode == "JOB" then
            local destination = workPointFor(actorState, actorState.job)
            local previous = actorState.destination
            if destination ~= nil and (previous == nil
                or math.abs(previous.x - destination.x) > 0.1
                or math.abs(previous.y - destination.y) > 0.1
                or math.abs(previous.z - destination.z) > 0.1) then
                actorState.destination = destination
                markPersistentDirty()
            end
        end
        updateTask(actorState)
    end
    local now = Protocol.nowMs()
    if #players > 0 and type(sendServerCommand) == "function"
        and now - Server.lastBroadcastAt >= Server.broadcastIntervalMs then
        Server.sequence = Server.sequence + 1
        state.server_timestamp_ms = now
        for _, actorState in ipairs(orderedStates()) do
            actorState.sequence = Server.sequence
            actorState.server_timestamp_ms = now
            pcall(sendServerCommand, Protocol.module,
                Protocol.stateCommand, publicState(actorState))
        end
        Server.lastBroadcastAt = now
    end
    savePersistentRoster(false)
    Server.lastTickAt = now
    return true
end

function Server.execute(message)
    if Config.bodyMode ~= "client_survivor" then
        return false, "client-survivor command received while another body mode is active"
    end
    if type(message) ~= "table" or Server.state == nil then
        return false, "client-survivor actor is waiting for a connected player"
    end
    local action = message.action
    local state = Server.states[message.npc_id]
    if state == nil then
        return false, "client-survivor actor is not in the configured roster"
    end
    markPersistentDirty()

    if action == "SAY" then
        if not Protocol.safeText(message.text, Protocol.maxSpeech, false) then
            return false, "client-survivor speech is malformed"
        end
        if type(sendServerCommand) ~= "function" then
            return false, "client-survivor speech transport is unavailable"
        end
        Server.speechSequence = Server.speechSequence + 1
        local speech = {
            protocol = Protocol.version,
            actor_id = state.actor_id,
            speech_sequence = Server.speechSequence,
            text = message.text
        }
        local ok = pcall(sendServerCommand, Protocol.module,
            Protocol.speechCommand, speech)
        if not ok then return false, "client-survivor speech transport failed" end
        log("sent speech to client-rendered actor '" .. tostring(state.actor_id) .. "'")
        return true, "speech sent to client-rendered actor"
    end

    if action == "ATTACK" then
        local kind = targetInfo(message)
        if kind ~= "nearby_threat" then
            return false, "ATTACK requires the nearby_threat semantic target"
        end
        -- ATTACK is an intent, not a request to name or move to an arbitrary
        -- zombie. Java selects only live ordinary IsoZombies in its bounded
        -- hunt radius and owns the lethal firearm result.
        state.control_mode = "COMBAT"
        state.combat_mode = "HUNT"
        state.task = "ATTACK"
        state.mode = "PARTY"
        state.target_username = nil
        state.follow_username = nil
        state.target_actor_id = nil
        state.destination = nil
        state.arrival_task = nil
        return true, "Goblin attack mode enabled; Java authority is scanning for hostile zombies"
    end

    if action == "NOOP" then
        state.server_timestamp_ms = Protocol.nowMs()
        markPersistentDirty()
        return true, "client-survivor actor acknowledged no-op"
    end

    if action == "DEBUG_KILL" then
        -- This path exists only to make the local death/recreate gate
        -- testable while normal managed humans remain god-mode protected. It
        -- is not a gameplay command and requires an exact local-test reason
        -- in addition to both explicit development flags.
        if not Config.developmentMode or not Config.allowTestCommands
            or message.reason ~= "local-test" then
            return false, "local survivor death test is disabled"
        end
        local marker = rawget(_G, "markGoblinHumanDead")
        if type(marker) ~= "function" then
            return false, "Storm death-test hook is unavailable"
        end
        local ok, marked = pcall(marker, state.actor_id, "local_test")
        if not ok or marked ~= true then
            return false, "survivor body could not be marked dead"
        end
        state.task = "DEBUG_KILL"
        state.combat_status = "debug_dead"
        return true, "local survivor death test accepted"
    end

    if action == "DEBUG_SPAWN_ZOMBIE" then
        -- This is a deterministic local combat fixture, not a gameplay
        -- spawn API. Keep it behind both disposable-development flags, an
        -- exact reason, and the driver-only test token. It creates an
        -- ordinary networked zombie near the custom human body; it never
        -- replaces or masquerades as the survivor.
        if not Config.developmentMode or not Config.allowTestCommands
            or message.reason ~= "local-test"
            or message.authority_token ~= "local-combat-test" then
            return false, "local combat fixture is disabled"
        end
        local spawn = rawget(_G, "spawnGoblinCombatFixture")
        if type(spawn) ~= "function" then
            return false, "Storm combat-fixture hook is unavailable"
        end
        local ok, created = pcall(spawn, state.actor_id)
        if not ok or created ~= true then
            return false, "ordinary zombie combat fixture could not be spawned"
        end
        state.control_mode = "COMBAT"
        state.combat_mode = "HUNT"
        state.task = "ATTACK"
        state.mode = "PARTY"
        state.target_username = nil
        state.follow_username = nil
        state.target_actor_id = nil
        state.destination = nil
        state.arrival_task = nil
        return true, "local ordinary zombie combat fixture spawned"
    end

    if action == "HOLD_POSITION" or action == "REST" then
        if setHold(state, action, "PARTY", statePoint(state)) then
            return true, "client-survivor actor is holding position"
        end
        return false, "client-survivor actor has no current position"
    end

    if action == "LEAVE_PARTY" then
        if setHold(state, "HOLD", "ROAM", statePoint(state)) then
            return true, "client-survivor actor left the party and is holding position"
        end
        return false, "client-survivor actor has no current position"
    end

    if action == "FOLLOW" or action == "JOIN_PARTY" or action == "DEFEND_PLAYER" then
        local kind, label = targetInfo(message)
        if kind ~= "player" then
            return false, "client-survivor follow commands require an online player target"
        end
        local player = findPlayer(label)
        if player == nil then return false, "target player is not online" end
        if setFollow(state, action, player) then
            return true, "client-survivor actor is following " .. tostring(playerName(player))
        end
        return false, "target player has no usable username"
    end

    if action == "FOLLOW_GOBLIN" then
        local kind = targetInfo(message)
        if kind ~= "goblin" then
            return false, "FOLLOW_GOBLIN requires a Goblin target"
        end
        if setFollowActor(state, action, Server.states[Config.npcId]) then
            return true, "client-survivor actor is following Goblin"
        end
        return false, "client-survivor actor cannot follow itself or a missing Goblin"
    end

    if action == "MOVE_TO" or action == "REGROUP"
        or action == "SEARCH" or action == "SCAVENGE"
        or action == "LOOT_AREA" then
        local point, detail = resolvePoint(message, state)
        if point == nil then return false, detail end
        if setDestination(state, action, "PARTY", point) then
            return true, "client-survivor actor accepted deterministic movement target"
        end
        return false, "client-survivor actor could not set movement target"
    end

    if action == "GO_HOME" or action == "RETURN_TO_BASE"
        or action == "GUARD" or action == "PATROL"
        or action == "DEFEND_AREA" or action == "RETREAT"
        or action == "FLEE" or action == "CLEAR_BUILDING" then
        local point, detail = resolvePoint(message, state)
        if point == nil then return false, detail end
        if action == "GO_HOME" or action == "RETURN_TO_BASE" then
            if setDestination(state, action, "PARTY", point) then
                return true, "client-survivor actor is returning to its anchored home"
            end
            return false, "client-survivor actor could not set home destination"
        end
        if action == "RETREAT" or action == "FLEE" then
            if setDestination(state, action, "SAFE", point, action) then
                return true, "client-survivor actor is retreating to the resolved safe point"
            end
            return false, "client-survivor actor could not set retreat destination"
        end
        if setDestination(state, action, "ROAM", point, action) then
            return true, "client-survivor actor accepted deterministic area target"
        end
        return false, "client-survivor actor could not set area target"
    end

    if action == "FORM_SQUAD" then
        local moved = 0
        if type(message.members) == "table" then
            for _, memberId in ipairs(message.members) do
                local member = Server.states[memberId]
                if member ~= nil and setFollowActor(member, "FOLLOW_GOBLIN", Server.states[Config.npcId]) then
                    moved = moved + 1
                end
            end
        end
        state.task = "FORM_SQUAD"
        state.mode = "PARTY"
        return true, "client-survivor squad formed; " .. tostring(moved) .. " actor(s) assigned"
    end

    if action == "DISMISS_SQUAD" then
        local released = 0
        for _, actorState in ipairs(orderedStates()) do
            if actorState.actor_id ~= Config.npcId
                and actorState.control_mode == "FOLLOW_ACTOR" then
                if setHold(actorState, "HOLD", "ROAM", statePoint(actorState)) then
                    released = released + 1
                end
            end
        end
        state.task = "DISMISS_SQUAD"
        return true, "client-survivor squad dismissed; " .. tostring(released) .. " actor(s) released"
    end

    if action == "ASSIGN_JOB" then
        local job = type(message.job) == "string" and string.upper(message.job) or ""
        if not ALLOWED_WORK_JOBS[job] then
            return false, "unsupported client-survivor job"
        end
        state.job = job
        state.task = "JOB_" .. job
        state.mode = "WORK"
        state.control_mode = "JOB"
        state.target_username = nil
        state.follow_username = nil
        state.target_actor_id = nil
        state.arrival_task = nil
        state.destination = workPointFor(state, job)
        state.combat_mode = "HUNT"
        state.manual_control = true
        state.work_status = "assigned"
        return true, "client-survivor actor assigned job " .. job
    end

    if action == "SECURE_BASE" then
        if not BaseManager.hasAnchor() then
            return false, "home base has not been set"
        end
        local point, detail = resolvePoint({ target = { kind = "home_base", label = "home base" } }, state)
        if point == nil then return false, detail end
        if setDestination(state, action, "ROAM", point, "GUARD") then
            return true, "client-survivor actor is securing the anchored home base"
        end
        return false, "client-survivor actor could not set base destination"
    end

    -- Do not fall back to a zombie or pretend that the visual-only actor has
    -- combat/inventory APIs. These actions remain explicit until their
    -- client-side human controller is implemented.
    return false, "action " .. tostring(action)
        .. " is not implemented by the client-survivor adapter"
end

return Server
