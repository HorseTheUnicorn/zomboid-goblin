local Perception = {}
local BaseManager = require("GoblinSurvivor/BaseManager")
local NPCRegistry

local function legacyRegistry()
    if NPCRegistry == nil then
        NPCRegistry = require("GoblinSurvivor/NPCRegistry")
    end
    return NPCRegistry
end

local function text(value)
    return type(value) == "string" and string.lower(value) or ""
end

local function eachPlayer(callback)
    if type(getOnlinePlayers) ~= "function" then return end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return end
    local count = type(players.size) == "function" and players:size() or #players
    for index = 0, count - 1 do
        local player = type(players.get) == "function" and players:get(index) or players[index + 1]
        if player ~= nil then callback(player) end
    end
end

local function playerFor(label)
    local wanted = text(label)
    local result = nil
    eachPlayer(function(player)
        if result ~= nil then return end
        local username = type(player.getUsername) == "function" and player:getUsername() or ""
        if text(username) == wanted then result = player end
    end)
    return result
end

local function position(object)
    if object == nil or type(object.getX) ~= "function"
        or type(object.getY) ~= "function" or type(object.getZ) ~= "function" then
        return nil
    end
    return { x = object:getX(), y = object:getY(), z = object:getZ() }
end

local function eachZombie(callback)
    if type(getCell) ~= "function" then return end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil or type(cell.getZombieList) ~= "function" then return end
    local okList, zombies = pcall(function() return cell:getZombieList() end)
    if not okList or zombies == nil then return end
    local count = 0
    if type(zombies.size) == "function" then
        local okSize, size = pcall(function() return zombies:size() end)
        if not okSize or type(size) ~= "number" then return end
        count = size
    elseif type(zombies) == "table" then
        count = #zombies
    end
    for index = 0, count - 1 do
        local zombie = type(zombies.get) == "function"
            and zombies:get(index) or zombies[index + 1]
        if zombie ~= nil then callback(zombie) end
    end
end

local function isUsableZombie(zombie)
    if zombie == nil then return false end
    if type(zombie.isExistInTheWorld) == "function" then
        local ok, exists = pcall(function() return zombie:isExistInTheWorld() end)
        if ok and not exists then return false end
    end
    if type(zombie.isDead) == "function" then
        local ok, dead = pcall(function() return zombie:isDead() end)
        if ok and dead then return false end
    end
    if type(zombie.isPlayer) == "function" then
        local ok, player = pcall(function() return zombie:isPlayer() end)
        if ok and player then return false end
    end
    if type(zombie.getModData) == "function" then
        local ok, data = pcall(function() return zombie:getModData() end)
        if ok and type(data) == "table"
            and (data.goblin_owned == true or data.goblin_friendly == true) then
            return false
        end
    end
    return position(zombie) ~= nil
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

function Perception.anchor()
    local result = nil
    eachPlayer(function(player) if result == nil then result = player end end)
    return result
end

function Perception.resolveTarget(target, zombie)
    if type(target) ~= "table" then return nil, "target is missing" end
    local kind = type(target.kind) == "string" and string.lower(target.kind) or ""
    local label = target.name or target.label or target.player
    if kind == "player" then
        local resolved = position(playerFor(label))
        return resolved, resolved and "player target" or "player is not online"
    end
    if kind == "goblin" then
        local resolved = position(legacyRegistry().findGoblin())
        return resolved, resolved and "Goblin target" or "Goblin is not present"
    end
    if kind == "home_base" or kind == "base" then
        local base = BaseManager.point()
        return base, base and "persistent home base" or "home base has not been set"
    end
    if kind == "nearby_threat" or kind == "escape_route" or kind == "current_position" then
        local resolved = position(zombie)
        return resolved, resolved and "local semantic target" or "NPC position unavailable"
    end
    local resolved = position(Perception.anchor())
    if resolved ~= nil then
        -- Named areas/buildings are resolved by the server-side perception
        -- layer. The model never receives these exact values.
        return resolved, "server semantic anchor"
    end
    return nil, "no local semantic target"
end

function Perception.nearestThreat(zombie)
    local origin = position(zombie)
    if origin == nil then return nil end
    local closest = nil
    local closestDistance = 32 * 32
    eachZombie(function(candidate)
        if candidate ~= zombie and isUsableZombie(candidate) then
            local point = position(candidate)
            local distance = distanceSquared(origin, point)
            if distance <= closestDistance then
                closest = candidate
                closestDistance = distance
            end
        end
    end)
    return closest
end

function Perception.nearbyPlayers()
    local result = {}
    eachPlayer(function(player)
        local name = type(player.getUsername) == "function" and player:getUsername() or ""
        if name ~= "" then table.insert(result, { id = name, online = true }) end
    end)
    return result
end

function Perception.coarseState(zombie)
    local result = { nearby_players = Perception.nearbyPlayers(), npc_id = "goblin.primary" }
    if position(zombie) ~= nil then result.location_bucket = "local" end
    result.threat_level = Perception.nearestThreat(zombie) ~= nil and "near" or "none"
    return result
end

return Perception
