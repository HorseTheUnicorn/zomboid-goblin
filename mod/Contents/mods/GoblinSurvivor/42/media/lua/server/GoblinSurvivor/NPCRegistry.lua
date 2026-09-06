local Config = require("GoblinSurvivor/Config")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")

local NPCRegistry = {
    entries = {},
    loaded = false,
    -- Keep one outstanding body request here. The native creator normally
    -- returns synchronously, while this state also protects the event bridge
    -- if a runtime emits its create callback during the Java call.
    spawnPending = false,
    pendingSpawn = nil,
    spawnTargetId = nil,
    -- These fields remain the public Goblin spawn diagnostic used by existing
    -- telemetry and operations tooling.
    spawnBlocked = false,
    spawnNextAt = 0,
    lastBindWarningAt = 0,
    spawnStatus = "idle",
    spawnAttempts = 0,
    spawnWindowStartedAt = 0,
    lastSpawnDetail = "",
    lastBindScanAt = 0
}

local MANAGED_ROSTER = {
    { npc_id = "npc.sarah", name = "Sarah", role = "medic" },
    { npc_id = "npc.bob", name = "Bob", role = "guard" },
    { npc_id = "npc.dave", name = "Dave", role = "hauler" },
    { npc_id = "npc.ellen", name = "Ellen", role = "farmer" },
    { npc_id = "npc.mike", name = "Mike", role = "builder" },
    { npc_id = "npc.june", name = "June", role = "scout" },
    { npc_id = "npc.lee", name = "Lee", role = "medic" },
    { npc_id = "npc.rosa", name = "Rosa", role = "mechanic" }
}

local SPAWN_REQUEST_TTL_MS = 10000
local SPAWN_RETRY_MS = 60000
local SPAWN_DEATH_COOLDOWN_MS = 30000
local SPAWN_WINDOW_MS = 10 * 60 * 1000
local MAX_SPAWN_ATTEMPTS = 3
local BIND_SCAN_INTERVAL_MS = 1000
local spawnStates = {}

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] NPCRegistry: " .. tostring(message))
    end
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function validId(value)
    return type(value) == "string" and #value >= 1 and #value <= 96
        and string.find(value, "^[A-Za-z0-9_%.:%-]+$") ~= nil
end

local function validText(value, maximum)
    return type(value) == "string" and #value >= 1 and #value <= maximum
end

local function persistentData()
    if type(ModData) ~= "table" or type(ModData.getOrCreate) ~= "function" then
        return nil
    end
    local ok, data = pcall(ModData.getOrCreate, "GoblinSurvivor")
    return ok and type(data) == "table" and data or nil
end

local function position(object)
    if object == nil or type(object.getX) ~= "function"
        or type(object.getY) ~= "function" or type(object.getZ) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return object:getX(), object:getY(), object:getZ()
    end)
    if not ok or type(x) ~= "number" or type(y) ~= "number"
        or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function onlineAnchor()
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return nil end
    if type(players.get) == "function" then
        local okSize, count = pcall(function() return players:size() end)
        if not okSize or type(count) ~= "number" or count < 1 then return nil end
        local okFirst, player = pcall(function() return players:get(0) end)
        if okFirst then return player end
    end
    if type(players) == "table" and #players > 0 then return players[1] end
    return nil
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function zombieList()
    if type(getCell) ~= "function" then return nil end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil or type(cell.getZombieList) ~= "function" then
        return nil
    end
    local okList, zombies = pcall(function() return cell:getZombieList() end)
    return okList and zombies or nil
end

local function bodyExists(zombie)
    if zombie == nil or type(zombie.isExistInTheWorld) ~= "function" then
        return true
    end
    local ok, exists = pcall(function() return zombie:isExistInTheWorld() end)
    return not ok or exists == true
end

local function bodyDead(zombie)
    if zombie == nil or type(zombie.isDead) ~= "function" then return false end
    local ok, dead = pcall(function() return zombie:isDead() end)
    return ok and dead == true
end

local function rosterSpec(npcId)
    if npcId == Config.npcId then
        return { npc_id = npcId, name = Config.npcName, role = Config.npcRole }
    end
    for _, spec in ipairs(MANAGED_ROSTER) do
        if spec.npc_id == npcId then return spec end
    end
    return nil
end

local function entryIds()
    local result = { Config.npcId }
    local count = tonumber(Config.managedNpcCount) or 0
    if count < 0 then count = 0 end
    if count > #MANAGED_ROSTER then count = #MANAGED_ROSTER end
    for index = 1, count do
        local candidate = MANAGED_ROSTER[index].npc_id
        if candidate ~= Config.npcId then table.insert(result, candidate) end
    end
    return result
end

local function savedRecord(data, npcId)
    if data == nil then return nil end
    if npcId == Config.npcId then return data.goblin end
    if type(data.npcs) == "table" then return data.npcs[npcId] end
    return nil
end

local function makeEntry(spec, saved)
    local entry = {
        npc_id = spec.npc_id,
        name = spec.name,
        role = spec.role,
        base_job = spec.role,
        expedition_role = "companion",
        active = true,
        alive = true,
        zombie = nil,
        last_seen = 0,
        home_base = "base.primary",
        squad_id = nil
    }
    if type(saved) ~= "table" then return entry end
    if saved.active == false then entry.active = false end
    if saved.alive == false then entry.alive = false end
    if validText(saved.name, 32) then entry.name = saved.name end
    if validText(saved.role, 32) then entry.role = string.lower(saved.role) end
    if validText(saved.base_job, 32) then entry.base_job = string.lower(saved.base_job) end
    if validText(saved.expedition_role, 32) then
        entry.expedition_role = string.lower(saved.expedition_role)
    end
    if validText(saved.home_base, 96) then entry.home_base = saved.home_base end
    if validId(saved.squad_id) then entry.squad_id = saved.squad_id end
    if type(saved.last_seen) == "number" then entry.last_seen = saved.last_seen end
    return entry
end

local function spawnState(npcId)
    local state = spawnStates[npcId]
    if state == nil then
        state = {
            blocked = false,
            nextAt = 0,
            attempts = 0,
            windowStartedAt = 0,
            status = "idle",
            detail = ""
        }
        spawnStates[npcId] = state
    end
    return state
end

local function syncPublicSpawnState(npcId)
    if npcId ~= Config.npcId then return end
    local state = spawnState(npcId)
    NPCRegistry.spawnBlocked = state.blocked
    NPCRegistry.spawnNextAt = state.nextAt
    NPCRegistry.spawnAttempts = state.attempts
    NPCRegistry.spawnWindowStartedAt = state.windowStartedAt
    NPCRegistry.spawnStatus = state.status
    NPCRegistry.lastSpawnDetail = state.detail
end

local function setSpawnStatus(npcId, status, detail)
    local state = spawnState(npcId)
    state.status = status
    state.detail = detail or ""
    syncPublicSpawnState(npcId)
end

local function prepareSpawnWindow(npcId, timestamp)
    local state = spawnState(npcId)
    if state.windowStartedAt == 0
        or timestamp - state.windowStartedAt >= SPAWN_WINDOW_MS then
        state.windowStartedAt = timestamp
        state.attempts = 0
    end
    syncPublicSpawnState(npcId)
end

local function clearPending(npcId)
    if NPCRegistry.spawnTargetId == npcId then
        NPCRegistry.spawnPending = false
        NPCRegistry.pendingSpawn = nil
        NPCRegistry.spawnTargetId = nil
    end
end

local function scheduleRetry(npcId, status, detail, delay)
    local timestamp = nowMs()
    local state = spawnState(npcId)
    prepareSpawnWindow(npcId, timestamp)
    clearPending(npcId)
    if state.attempts >= MAX_SPAWN_ATTEMPTS then
        state.blocked = true
        state.nextAt = 0
        setSpawnStatus(npcId, "blocked", "spawn attempts exhausted for the bounded retry window")
        log(npcId .. " spawn blocked after " .. tostring(state.attempts)
            .. " attempts: " .. tostring(detail))
        return
    end
    state.blocked = false
    state.nextAt = timestamp + (delay or SPAWN_RETRY_MS)
    setSpawnStatus(npcId, status, detail)
    log(npcId .. " " .. tostring(detail) .. "; next bounded attempt is delayed")
end

local function saveEntry(record, entry)
    record[entry.npc_id] = {
        npc_id = entry.npc_id,
        name = entry.name,
        role = entry.role,
        base_job = entry.base_job,
        expedition_role = entry.expedition_role,
        active = entry.active,
        alive = entry.alive,
        last_seen = entry.last_seen,
        home_base = entry.home_base,
        squad_id = entry.squad_id
    }
end

function NPCRegistry.load()
    if NPCRegistry.loaded then return end
    local data = persistentData()
    for _, npcId in ipairs(entryIds()) do
        local spec = rosterSpec(npcId)
        if spec ~= nil then
            NPCRegistry.entries[npcId] = makeEntry(spec, savedRecord(data, npcId))
        end
    end
    NPCRegistry.loaded = true
    syncPublicSpawnState(Config.npcId)
end

function NPCRegistry.save()
    local data = persistentData()
    if data == nil then return false end
    local goblin = NPCRegistry.entries[Config.npcId]
    if goblin == nil then return false end
    data.goblin = {
        npc_id = goblin.npc_id,
        name = goblin.name,
        role = goblin.role,
        active = goblin.active,
        alive = goblin.alive,
        last_seen = goblin.last_seen,
        home_base = goblin.home_base,
        squad_id = goblin.squad_id
    }
    data.npcs = {}
    for npcId, entry in pairs(NPCRegistry.entries) do
        if npcId ~= Config.npcId then saveEntry(data.npcs, entry) end
    end
    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, "GoblinSurvivor")
    end
    return true
end

function NPCRegistry.get(npcId)
    NPCRegistry.load()
    return NPCRegistry.entries[npcId]
end

function NPCRegistry.ids()
    NPCRegistry.load()
    local result = {}
    for _, npcId in ipairs(entryIds()) do
        if NPCRegistry.entries[npcId] ~= nil then table.insert(result, npcId) end
    end
    return result
end

function NPCRegistry.snapshot()
    NPCRegistry.load()
    local result = {}
    for _, npcId in ipairs(entryIds()) do
        local entry = NPCRegistry.entries[npcId]
        if entry ~= nil and entry.active == true then
            local present = entry.zombie ~= nil
                and bodyExists(entry.zombie) and not bodyDead(entry.zombie)
            local status = NpcAdapter.status(entry.zombie, npcId)
            table.insert(result, {
                npc_id = entry.npc_id,
                name = entry.name,
                role = entry.role,
                base_job = entry.base_job,
                expedition_role = entry.expedition_role,
                alive = entry.alive == true and present,
                active = true,
                body_present = present,
                mode = status.mode,
                task = status.task,
                target_player = status.target_player,
                target_npc_id = status.target_npc_id,
                friendly = status.friendly == true,
                protected = status.protected == true,
                squad_id = entry.squad_id,
                home_base = entry.home_base
            })
        end
    end
    return result
end

function NPCRegistry.snapshotExact()
    NPCRegistry.load()
    local result = {}
    for _, npcId in ipairs(entryIds()) do
        local entry = NPCRegistry.entries[npcId]
        local present = entry ~= nil and entry.zombie ~= nil
            and bodyExists(entry.zombie) and not bodyDead(entry.zombie)
        local point = present and position(entry.zombie) or nil
        if entry ~= nil and entry.active == true and point ~= nil then
            point.entity_id = entry.npc_id
            point.npc_id = entry.npc_id
            point.kind = "npc"
            point.name = entry.name
            point.role = entry.role
            point.squad_id = entry.squad_id
            table.insert(result, point)
        end
    end
    return result
end

function NPCRegistry.body(npcId)
    return NPCRegistry.find(npcId)
end

function NPCRegistry.setSquad(npcId, squadId)
    NPCRegistry.load()
    local entry = NPCRegistry.entries[npcId]
    if entry == nil then return false end
    if squadId ~= nil and not validId(squadId) then return false end
    entry.squad_id = squadId
    return NPCRegistry.save()
end

function NPCRegistry.entryForBody(body)
    NPCRegistry.load()
    if body == nil then return nil end
    for npcId, entry in pairs(NPCRegistry.entries) do
        if entry.zombie == body then return entry, npcId end
    end
    return nil
end

local function markBound(npcId, zombie, detail)
    local entry = NPCRegistry.entries[npcId]
    if entry == nil then return false end
    entry.zombie = zombie
    entry.active = true
    entry.alive = true
    entry.last_seen = nowMs()
    local state = spawnState(npcId)
    state.blocked = true
    state.nextAt = 0
    state.attempts = 0
    state.windowStartedAt = 0
    clearPending(npcId)
    setSpawnStatus(npcId, "present", detail)
    NPCRegistry.save()
    return true
end

local function bindExisting()
    local timestamp = nowMs()
    if timestamp - NPCRegistry.lastBindScanAt < BIND_SCAN_INTERVAL_MS then
        return nil, nil
    end
    NPCRegistry.lastBindScanAt = timestamp
    local function scan(list)
        if list == nil then return nil, nil end
        local count = type(list.size) == "function" and list:size() or #list
        for index = 0, count - 1 do
            local body = type(list.get) == "function"
                and list:get(index) or list[index + 1]
            if body ~= nil then
                for npcId, entry in pairs(NPCRegistry.entries) do
                    if entry.active == true and entry.zombie == nil
                        and NpcAdapter.removeForeign(body, npcId) then
                        log("removed a stale foreign-managed body for " .. npcId)
                    elseif entry.active == true and entry.zombie == nil
                        and NpcAdapter.isCandidate(body, npcId) then
                        local prepared = NpcAdapter.prepare(
                            body, npcId, nil, entry.name, entry.role
                        )
                        if prepared and NpcAdapter.isOwned(body, npcId) then
                            markBound(npcId, body,
                                "friendly managed native body bound")
                            return body, npcId
                        end
                        if timestamp - NPCRegistry.lastBindWarningAt >= 30000 then
                            log("found " .. npcId
                                .. " profile candidate but friendly bind failed")
                            NPCRegistry.lastBindWarningAt = timestamp
                        end
                    end
                end
            end
        end
        return nil, nil
    end
    return scan(zombieList())
end

function NPCRegistry.find(npcId)
    NPCRegistry.load()
    local entry = NPCRegistry.entries[npcId]
    if entry == nil then return nil end

    if NPCRegistry.spawnPending and NPCRegistry.pendingSpawn ~= nil
        and NPCRegistry.pendingSpawn.npc_id == npcId
        and nowMs() >= (NPCRegistry.pendingSpawn.deadline or 0) then
        scheduleRetry(npcId, "retry_wait",
            "bounded spawn request expired without a friendly managed body", SPAWN_RETRY_MS)
    end
    if entry.zombie == nil then
        bindExisting()
    end
    if entry.zombie ~= nil and not bodyExists(entry.zombie) then
        entry.zombie = nil
        entry.alive = false
        local state = spawnState(npcId)
        state.blocked = false
        state.nextAt = nowMs() + SPAWN_DEATH_COOLDOWN_MS
        setSpawnStatus(npcId, "retry_wait", "managed body unloaded; waiting before replacement")
        NPCRegistry.save()
    elseif entry.zombie ~= nil and bodyDead(entry.zombie) then
        entry.zombie = nil
        entry.alive = false
        local state = spawnState(npcId)
        state.blocked = false
        state.nextAt = nowMs() + SPAWN_DEATH_COOLDOWN_MS
        setSpawnStatus(npcId, "retry_wait", "managed body died; waiting before replacement")
        NPCRegistry.save()
    elseif entry.zombie ~= nil then
        entry.alive = true
        entry.last_seen = nowMs()
    end
    return entry.zombie
end

function NPCRegistry.findGoblin()
    return NPCRegistry.find(Config.npcId)
end

function NPCRegistry.onZombieCreate(zombie)
    if zombie == nil then return false end
    NPCRegistry.load()

    -- Storm creates the fully-registered networked body first and marks its
    -- mod-data immediately afterward.  Its OnZombieCreate event therefore
    -- can arrive after the normal pending-spawn window has been cleared (or
    -- can be re-emitted by the bridge).  An explicit ownership marker is
    -- safe to adopt without a proximity reservation; ordinary zombies do not
    -- carry this marker and are never claimed here.
    for candidateId, candidateEntry in pairs(NPCRegistry.entries) do
        if candidateEntry.active == true and candidateEntry.zombie == nil
            and NpcAdapter.isCandidate(zombie, candidateId) then
            local prepared, detail = NpcAdapter.prepare(
                zombie, candidateId, nil, candidateEntry.name, candidateEntry.role
            )
            if prepared and NpcAdapter.isOwned(zombie, candidateId) then
                markBound(candidateId, zombie, "managed native body adopted from Storm")
                return true, "managed native body adopted from Storm"
            end
            if detail ~= nil then
                log("Storm body candidate for " .. candidateId
                    .. " could not be adopted: " .. tostring(detail))
            end
        end
    end

    if not NPCRegistry.spawnPending or NPCRegistry.pendingSpawn == nil then
        return false
    end
    local point = position(zombie)
    local pending = NPCRegistry.pendingSpawn
    if point == nil or pending.point == nil
        or distanceSquared(point, pending.point) > 25 then
        return false
    end
    NPCRegistry.load()
    local npcId = pending.npc_id
    local entry = NPCRegistry.entries[npcId]
    if entry == nil or entry.zombie ~= nil then return false, "managed NPC is already bound" end
    -- Native creation may emit OnZombieCreate before mod-data is populated.
    -- Never claim a normal population zombie; the adapter's short-lived
    -- spawn reservation is the only event-time fallback.
    if not NpcAdapter.isCandidate(zombie, npcId)
        and not NpcAdapter.isEventCandidate(zombie, npcId) then
        return false, "not a managed native body candidate"
    end
    local prepared, detail = NpcAdapter.prepare(
        zombie, npcId, nil, entry.name, entry.role
    )
    if not prepared or not NpcAdapter.isOwned(zombie, npcId) then
        NpcAdapter.discard(zombie, npcId)
        return false, detail
    end
    markBound(npcId, zombie, "managed native body bound from OnZombieCreate")
    return true, "managed native body bound from OnZombieCreate"
end

local function rosterOffset(npcId)
    local base = tonumber(Config.npcSpawnOffsetTiles) or 16
    for index, spec in ipairs(MANAGED_ROSTER) do
        if spec.npc_id == npcId then return base + (index * 4) end
    end
    return base
end

local function spawnEntry(npcId)
    NPCRegistry.load()
    local entry = NPCRegistry.entries[npcId]
    if entry == nil or entry.active ~= true then
        return nil, "managed NPC is inactive"
    end
    local existing = NPCRegistry.find(npcId)
    if existing ~= nil then return existing, "already present" end
    if NPCRegistry.spawnPending then
        return nil, "another managed NPC spawn request is pending"
    end

    local state = spawnState(npcId)
    if state.blocked then
        return nil, state.detail ~= "" and state.detail
            or "spawn blocked after bounded attempts"
    end
    if nowMs() < state.nextAt then
        setSpawnStatus(npcId, "retry_wait", "managed NPC spawn recovery cooldown")
        return nil, "managed NPC spawn recovery cooldown"
    end
    local anchor = onlineAnchor()
    if anchor == nil then
        setSpawnStatus(npcId, "waiting_anchor", "waiting for an online player anchor")
        return nil, "waiting for an online player anchor"
    end
    if not NpcAdapter.available() then
        log("spawn held for " .. npcId .. ": no friendly NPC adapter is available")
        setSpawnStatus(npcId, "waiting_engine", "friendly NPC adapter is unavailable")
        return nil, "friendly NPC adapter is unavailable"
    end
    local plannedPoint = NpcAdapter.spawnPoint(anchor, rosterOffset(npcId))
    if plannedPoint == nil then
        setSpawnStatus(npcId, "waiting_anchor", "online player anchor has no safe spawn point")
        return nil, "online player anchor has no safe spawn point"
    end
    local timestamp = nowMs()
    prepareSpawnWindow(npcId, timestamp)
    if state.attempts >= MAX_SPAWN_ATTEMPTS then
        state.blocked = true
        setSpawnStatus(npcId, "blocked", "spawn attempts exhausted for the bounded retry window")
        return nil, state.detail
    end
    state.attempts = state.attempts + 1
    state.blocked = true
    NPCRegistry.spawnPending = true
    NPCRegistry.spawnTargetId = npcId
    NPCRegistry.pendingSpawn = {
        npc_id = npcId,
        point = plannedPoint,
        deadline = timestamp + SPAWN_REQUEST_TTL_MS
    }
    setSpawnStatus(npcId, "request_pending", "spawn request " .. tostring(state.attempts)
        .. " of " .. tostring(MAX_SPAWN_ATTEMPTS))
    local ok, detail, zombie, spawnPoint = NpcAdapter.spawnIndividual(
        anchor, entry.npc_id, Config.npcProgram, entry.name, entry.role,
        rosterOffset(npcId)
    )
    if not ok then
        scheduleRetry(npcId, "retry_wait", detail, SPAWN_RETRY_MS)
        return nil, detail
    end
    -- The event may have bound the body synchronously inside the Java call.
    if not NPCRegistry.spawnPending then
        return NPCRegistry.find(npcId), detail
    end
    if zombie ~= nil and NpcAdapter.isOwned(zombie, npcId) then
        markBound(npcId, zombie, "friendly managed body returned by spawn API")
        return zombie, detail
    end
    if zombie ~= nil then
        NPCRegistry.spawnPending = false
        NPCRegistry.pendingSpawn = nil
        NPCRegistry.spawnTargetId = nil
        NpcAdapter.discard(zombie, npcId)
        local failure = "spawned body failed the friendly ownership proof"
        scheduleRetry(npcId, "retry_wait", failure, SPAWN_RETRY_MS)
        return nil, failure
    end
    NPCRegistry.pendingSpawn = {
        npc_id = npcId,
        point = spawnPoint or plannedPoint,
        deadline = nowMs() + SPAWN_REQUEST_TTL_MS
    }
    setSpawnStatus(npcId, "request_pending", detail)
    return nil, detail
end

function NPCRegistry.spawnGoblin()
    return spawnEntry(Config.npcId)
end

function NPCRegistry.ensureManaged()
    NPCRegistry.load()
    -- Do not create a worker roster before Goblin has a verified body. This
    -- keeps the first join deterministic and prevents an unanchored crowd.
    if NPCRegistry.findGoblin() == nil then
        return nil, "waiting for Goblin body before managed roster"
    end
    for _, npcId in ipairs(entryIds()) do
        if npcId ~= Config.npcId then
            local body = NPCRegistry.find(npcId)
            if body == nil then return spawnEntry(npcId) end
        end
    end
    return nil, "managed friendly roster is present"
end

function NPCRegistry.spawnState()
    NPCRegistry.load()
    local state = spawnState(Config.npcId)
    return {
        status = state.status,
        pending = NPCRegistry.spawnPending == true
            and NPCRegistry.spawnTargetId == Config.npcId,
        attempts = state.attempts,
        detail = state.detail
    }
end

function NPCRegistry.markRecovered(zombie, npcId)
    npcId = npcId or Config.npcId
    NPCRegistry.load()
    if NPCRegistry.entries[npcId] == nil then return false end
    local prepared = NpcAdapter.prepare(
        zombie, npcId, nil, NPCRegistry.entries[npcId].name,
        NPCRegistry.entries[npcId].role
    )
    if not prepared or not NpcAdapter.isOwned(zombie, npcId) then return false end
    return markBound(npcId, zombie, "managed friendly body recovered")
end

function NPCRegistry.markDead(npcId)
    npcId = npcId or Config.npcId
    NPCRegistry.load()
    local entry = NPCRegistry.entries[npcId]
    if entry == nil then return false end
    entry.zombie = nil
    entry.alive = false
    clearPending(npcId)
    local state = spawnState(npcId)
    state.blocked = false
    state.nextAt = nowMs() + SPAWN_DEATH_COOLDOWN_MS
    setSpawnStatus(npcId, "retry_wait", "managed NPC death recorded; replacement is bounded and delayed")
    NPCRegistry.save()
    return true
end

return NPCRegistry
