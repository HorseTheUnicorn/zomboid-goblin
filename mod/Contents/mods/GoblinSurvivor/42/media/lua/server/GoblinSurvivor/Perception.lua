local Perception = {}

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
    return result
end

return Perception
