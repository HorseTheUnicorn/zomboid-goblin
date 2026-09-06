-- Lightweight native friendly-survivor controller.
--
-- The body is a normal networked IsoZombie created by the public Build 42
-- createZombie() factory. Do not call an IsoZombie Java constructor from Lua:
-- the factory performs the engine registration needed by multiplayer.
--
-- The custom entity is never an IsoPlayer. IsoPlayer objects are used only as
-- read-only live navigation targets. The server owns the body, target choice,
-- and path request; clients receive normal PZ movement replication plus the
-- small state envelope in FriendlySurvivorNetwork.lua.
local Config = require("GoblinSurvivor/Config")
local Network = require("GoblinSurvivor/FriendlySurvivorNetwork")
local Protocol = require("GoblinSurvivor/FriendlySurvivorProtocol")

local FriendlySurvivor = {
    followRadiusTiles = 30,
    stopDistanceTiles = 2,
    pathIntervalMs = 250,
    started = false
}

local FOLLOW_RADIUS_SQUARED = 30 * 30
local STOP_DISTANCE_SQUARED = 2 * 2

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] FriendlySurvivor: " .. tostring(message))
    end
end

local function functionExists(object, name)
    return object ~= nil and type(object[name]) == "function"
end

local function safeCall(object, method, ...)
    if not functionExists(object, method) then return false end
    local ok = pcall(object[method], object, ...)
    return ok
end

local function bodyData(body)
    if not functionExists(body, "getModData") then return nil end
    local ok, data = pcall(function() return body:getModData() end)
    return ok and type(data) == "table" and data or nil
end

local function position(entity)
    return Protocol.position(entity)
end

local function distanceSquared2D(a, b)
    if a == nil or b == nil then return math.huge end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function isLivePlayer(player)
    if player == nil then return false end
    if functionExists(player, "isPlayer") then
        local ok, value = pcall(function() return player:isPlayer() end)
        if ok and value ~= true then return false end
    end
    if functionExists(player, "isDead") then
        local ok, value = pcall(function() return player:isDead() end)
        if ok and value == true then return false end
    end
    if functionExists(player, "isAlive") then
        local ok, value = pcall(function() return player:isAlive() end)
        if ok and value ~= true then return false end
    end
    return position(player) ~= nil
end

local function eachOnlinePlayer(callback)
    if type(getOnlinePlayers) ~= "function" then return end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return end
    local count = 0
    if type(players.size) == "function" then
        local okSize, value = pcall(function() return players:size() end)
        if not okSize or type(value) ~= "number" then return end
        count = value
    elseif type(players) == "table" then
        count = #players
    end
    for index = 0, count - 1 do
        local player = type(players.get) == "function"
            and players:get(index) or players[index + 1]
        if player ~= nil then callback(player) end
    end
end

local function playerName(player)
    if not functionExists(player, "getUsername") then return nil end
    local ok, value = pcall(function() return player:getUsername() end)
    if ok and Protocol.safeText(value, Protocol.maxUsername, false) then
        return value
    end
    return nil
end

local function nearestPlayer(body)
    local origin = position(body)
    if origin == nil then return nil, nil end
    local nearest = nil
    local nearestDistance = FOLLOW_RADIUS_SQUARED + 1
    eachOnlinePlayer(function(player)
        if isLivePlayer(player) then
            local point = position(player)
            local distance = distanceSquared2D(origin, point)
            if distance <= FOLLOW_RADIUS_SQUARED and distance < nearestDistance then
                nearest = player
                nearestDistance = distance
            end
        end
    end)
    if nearest == nil then return nil, nil end
    return nearest, nearestDistance
end

local function survivorDescriptor()
    local factory = rawget(_G, "SurvivorFactory")
    if not functionExists(factory, "CreateSurvivor") then return nil end
    local ok, descriptor = pcall(factory.CreateSurvivor)
    if ok and descriptor ~= nil then return descriptor end
    local survivorType = rawget(_G, "SurvivorType")
    local friendly = survivorType ~= nil and survivorType.Friendly or nil
    if friendly == nil then return nil end
    local okTyped, typedDescriptor = pcall(factory.CreateSurvivor, friendly)
    return okTyped and typedDescriptor or nil
end

local function markBody(body, npcId, displayName)
    local data = bodyData(body)
    if data == nil then return false end
    local changed = false
    local function setMarker(key, value)
        if data[key] ~= value then
            data[key] = value
            changed = true
        end
    end
    setMarker("goblin_friendly_survivor", true)
    setMarker("goblin_body_class", "IsoZombie")
    setMarker("goblin_npc_id", npcId or Config.npcId)
    setMarker("goblin_owned", true)
    setMarker("goblin_friendly", true)
    setMarker("goblin_hostile", false)
    setMarker("goblin_display_name", displayName or Config.npcName)
    setMarker("goblin_target_class", "IsoPlayer")
    setMarker("goblin_biting_disabled", true)
    setMarker("goblin_default_zombie_ai_stripped", true)
    if data.goblin_next_path_at == nil then
        data.goblin_next_path_at = 0
        changed = true
    end
    if changed and functionExists(body, "transmitModData") then
        pcall(body.transmitModData, body)
    end
    return true
end

-- Public Build 42 does not expose a per-instance Lua setter for every zombie
-- sound callback. We suppress the public causes of zombie audio and reset the
-- exposed sound-attraction fields when the runtime permits field writes.
-- If a future build adds explicit setters, they are used opportunistically.
local function stripDefaultZombieBehavior(body, preserveNavigation)
    if body == nil then return false end

    -- Never leave a player or world object as the zombie's hostile target.
    safeCall(body, "setTarget", nil)
    safeCall(body, "clearAggroList")
    safeCall(body, "setEatBodyTarget", nil, false)
    safeCall(body, "setThumpTarget", nil)
    safeCall(body, "setAttackTargetSquare", nil)
    if not preserveNavigation then
        safeCall(body, "setPath2", nil)
        safeCall(body, "setPathing", false)
    end

    -- Keep the body upright and capable of using the native path request while
    -- removing zombie-only states that can lead to a bite/thump transition.
    safeCall(body, "setCrawler", false)
    safeCall(body, "setFakeDead", false)
    safeCall(body, "setReanimatedPlayer", false)
    safeCall(body, "setReanimatedForGrappleOnly", false)
    safeCall(body, "setCanWalk", true)
    safeCall(body, "setZombiesDontAttack", true)

    -- These setters are not present on every Build 42 runtime. They are
    -- capability-gated rather than invented, so a missing setter is safe.
    safeCall(body, "setBite", false)
    safeCall(body, "setCantBite", true)
    safeCall(body, "setVoiceSoundName", "")
    safeCall(body, "setBiteSoundName", "")

    -- The Java-backed sound fields are not writable through Kahlua on the
    -- dedicated server; use only the supported setters above.
    return true
end

local function stopNavigation(body)
    safeCall(body, "setTarget", nil)
    safeCall(body, "clearAggroList")
    safeCall(body, "setThumpTarget", nil)
    safeCall(body, "setAttackTargetSquare", nil)
    safeCall(body, "setPath2", nil)
    safeCall(body, "setPathing", false)
end

local function requestPath(body, target, targetPoint, data)
    local now = Protocol.nowMs()
    local nextPathAt = tonumber(data.goblin_next_path_at) or 0
    if now < nextPathAt then return true end

    local accepted = false
    -- Coordinates are used only on the authoritative server. This avoids
    -- assigning an IsoPlayer as a zombie target, which would re-enable attack
    -- state; pathToLocationF is navigation, not combat targeting.
    if functionExists(body, "pathToLocationF") then
        accepted = pcall(body.pathToLocationF, body,
            targetPoint.x, targetPoint.y, targetPoint.z)
    elseif functionExists(body, "pathToLocation") then
        accepted = pcall(body.pathToLocation, body,
            math.floor(targetPoint.x), math.floor(targetPoint.y),
            math.floor(targetPoint.z))
    elseif functionExists(body, "pathToCharacter") then
        -- Compatibility fallback for a runtime without coordinate pathing.
        accepted = pcall(body.pathToCharacter, body, target)
    end

    -- pathToCharacter is allowed only as a navigation fallback. Clear the
    -- hostile target immediately afterward in case that overload sets it.
    safeCall(body, "setTarget", nil)
    data.goblin_next_path_at = now + FriendlySurvivor.pathIntervalMs
    data.goblin_path_requests = (tonumber(data.goblin_path_requests) or 0) + 1
    data.goblin_path_available = accepted == true
    return accepted == true
end

local function managedBody(body)
    local data = bodyData(body)
    if data == nil then return false end
    if data.goblin_friendly_survivor == true then return true end
    return data.goblin_engine == "native"
        and data.goblin_npc_id == Config.npcId
        and data.goblin_owned == true
        and data.goblin_friendly == true
end

function FriendlySurvivor.spawn(anchor, npcId, displayName)
    if anchor == nil then return false, "an online IsoPlayer anchor is required", nil end
    local create = rawget(_G, "createZombie")
    if type(create) ~= "function" then
        return false, "Build 42 createZombie is unavailable", nil
    end
    local descriptor = survivorDescriptor()
    if descriptor == nil then
        return false, "SurvivorFactory.CreateSurvivor is unavailable", nil
    end
    local origin = position(anchor)
    if origin == nil then return false, "anchor has no position", nil end
    local directions = rawget(_G, "IsoDirections")
    local direction = directions ~= nil and directions.S or nil
    local ok, body = pcall(create, origin.x + 1.5, origin.y + 1.5,
        origin.z, descriptor, 0, direction)
    if not ok or body == nil then
        return false, "createZombie returned no IsoZombie", nil
    end
    if not markBody(body, npcId, displayName) then
        return false, "IsoZombie mod-data API is unavailable", nil
    end
    stripDefaultZombieBehavior(body, false)
    return true, "native IsoZombie friendly survivor created", body
end

function FriendlySurvivor.isManaged(body)
    return managedBody(body)
end

function FriendlySurvivor.reassert(body)
    local data = bodyData(body)
    if not managedBody(body) or data == nil then return false end
    -- Explicit tasks and combat are owned by the deterministic action adapter;
    -- do not erase their intentional native target here.
    if data.goblin_combat == true or type(data.goblin_task) == "table" then
        return false
    end
    stripDefaultZombieBehavior(body, true)
    return true
end

function FriendlySurvivor.tick(body)
    if not managedBody(body) then return false end
    local data = bodyData(body)
    if data == nil then return false end
    markBody(body, data.goblin_npc_id, data.goblin_display_name)

    -- This scan is intentionally O(number of connected players), not a world
    -- scan. With one managed body it is cheap enough to run on every server
    -- tick; only native path requests and state packets are throttled.
    local target, distanceSquared = nearestPlayer(body)
    local mode = "IDLE"
    local distanceTiles = nil
    -- Explicit deterministic commands and an approved combat target outrank
    -- the idle nearest-player behavior. The scan above still happens every
    -- tick, which keeps telemetry current without stealing command authority.
    if data.goblin_combat == true or type(data.goblin_task) == "table" then
        data.goblin_follow_mode = "EXTERNAL_TASK"
        data.goblin_controller_tick_ms = Protocol.nowMs()
        Network.publish(body, target, nil, "EXTERNAL_TASK", false)
        return true
    end
    stripDefaultZombieBehavior(body, true)
    if target ~= nil then
        local targetPoint = position(target)
        distanceTiles = math.sqrt(distanceSquared)
        data.goblin_target_username = playerName(target)
        data.goblin_target_distance = distanceTiles
        if distanceSquared > STOP_DISTANCE_SQUARED and targetPoint ~= nil then
            mode = requestPath(body, target, targetPoint, data)
                and "FOLLOW" or "FOLLOW_UNAVAILABLE"
        else
            stopNavigation(body)
            data.goblin_next_path_at = Protocol.nowMs() + FriendlySurvivor.pathIntervalMs
            mode = "HOLD_NEAR_PLAYER"
        end
    else
        data.goblin_target_username = nil
        data.goblin_target_distance = nil
        stopNavigation(body)
    end
    data.goblin_follow_mode = mode
    data.goblin_controller_tick_ms = Protocol.nowMs()
    Network.publish(body, target, distanceTiles, mode, false)
    return true
end

function FriendlySurvivor.state(body)
    local data = bodyData(body)
    if not managedBody(body) or data == nil then return nil end
    return {
        entity_class = "IsoZombie",
        npc_id = data.goblin_npc_id,
        target_username = data.goblin_target_username,
        distance_tiles = data.goblin_target_distance,
        mode = data.goblin_follow_mode or "IDLE",
        biting_disabled = data.goblin_biting_disabled == true,
        default_zombie_ai_stripped = data.goblin_default_zombie_ai_stripped == true,
        path_requests = data.goblin_path_requests or 0
    }
end

function FriendlySurvivor.start()
    if FriendlySurvivor.started then return true end
    Network.start()
    FriendlySurvivor.started = true
    log("native IsoZombie controller ready; follow radius="
        .. tostring(FriendlySurvivor.followRadiusTiles) .. " tiles")
    return true
end

return FriendlySurvivor
