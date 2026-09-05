-- Shared spatial cache for the standalone survivor engine.
-- One cell refresh feeds all survivors; individual brains only query nearby
-- buckets instead of scanning the entire zombie list on every update.
local Identity = require("GoblinSurvivor/Identity")

local Perception = {
    bucketSize = 10,
    refreshIntervalMs = 500,
    state = {
        lastRefreshAt = 0,
        generation = 0,
        zombies = {},
        survivors = {},
        players = {},
        zombieList = {},
        survivorList = {},
        playerList = {},
        scans = 0,
        candidates = 0
    }
}

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

function Perception.position(entity)
    if entity == nil or type(entity.getX) ~= "function"
        or type(entity.getY) ~= "function" or type(entity.getZ) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return entity:getX(), entity:getY(), entity:getZ()
    end)
    if not ok or type(x) ~= "number" or type(y) ~= "number"
        or type(z) ~= "number" then return nil end
    return { x = x, y = y, z = z }
end

local function usable(entity)
    if entity == nil or Perception.position(entity) == nil then return false end
    if type(entity.isExistInTheWorld) == "function" then
        local ok, exists = pcall(function() return entity:isExistInTheWorld() end)
        if ok and not exists then return false end
    end
    if type(entity.isDead) == "function" then
        local ok, dead = pcall(function() return entity:isDead() end)
        if ok and dead then return false end
    end
    return true
end

local function addBucket(buckets, entity)
    local point = Perception.position(entity)
    if point == nil then return end
    local bx = math.floor(point.x / Perception.bucketSize)
    local by = math.floor(point.y / Perception.bucketSize)
    local key = tostring(bx) .. ":" .. tostring(by)
    if buckets[key] == nil then buckets[key] = {} end
    table.insert(buckets[key], entity)
end

local function eachCollection(collection, callback)
    if collection == nil then return end
    local count = 0
    if type(collection.size) == "function" then
        local ok, value = pcall(function() return collection:size() end)
        if not ok or type(value) ~= "number" then return end
        count = value
    elseif type(collection) == "table" then
        count = #collection
    end
    for index = 0, count - 1 do
        local value = type(collection.get) == "function"
            and collection:get(index) or collection[index + 1]
        if value ~= nil then callback(value) end
    end
end

local function worldZombies()
    if type(getCell) ~= "function" then return nil end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil or type(cell.getZombieList) ~= "function" then return nil end
    local okList, list = pcall(function() return cell:getZombieList() end)
    return okList and list or nil
end

local function onlinePlayers()
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    return ok and players or nil
end

function Perception.refresh(timestamp, force)
    timestamp = timestamp or nowMs()
    if not force and timestamp - Perception.state.lastRefreshAt < Perception.refreshIntervalMs then
        return false
    end
    local state = Perception.state
    state.zombies, state.survivors, state.players = {}, {}, {}
    state.zombieList, state.survivorList, state.playerList = {}, {}, {}
    eachCollection(worldZombies(), function(zombie)
        if usable(zombie) then
            if Identity.isManaged(zombie) then
                addBucket(state.survivors, zombie)
                table.insert(state.survivorList, zombie)
            else
                addBucket(state.zombies, zombie)
                table.insert(state.zombieList, zombie)
            end
        end
    end)
    eachCollection(onlinePlayers(), function(player)
        if usable(player) then
            addBucket(state.players, player)
            table.insert(state.playerList, player)
        end
    end)
    state.lastRefreshAt = timestamp
    state.generation = state.generation + 1
    state.scans = state.scans + 1
    return true
end

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function nearbyFrom(buckets, origin, radius, filter)
    local point = type(origin) == "table" and origin.x ~= nil
        and origin or Perception.position(origin)
    if point == nil then return {} end
    local result = {}
    local radiusSquared = (tonumber(radius) or 0) ^ 2
    local width = math.ceil((tonumber(radius) or 0) / Perception.bucketSize)
    local centerX = math.floor(point.x / Perception.bucketSize)
    local centerY = math.floor(point.y / Perception.bucketSize)
    for bx = centerX - width, centerX + width do
        for by = centerY - width, centerY + width do
            local list = buckets[tostring(bx) .. ":" .. tostring(by)]
            if list ~= nil then
                for _, entity in ipairs(list) do
                    if (filter == nil or filter(entity)) then
                        local candidatePoint = Perception.position(entity)
                        if candidatePoint ~= nil
                            and distanceSquared(point, candidatePoint) <= radiusSquared then
                            table.insert(result, entity)
                        end
                    end
                end
            end
        end
    end
    Perception.state.candidates = Perception.state.candidates + #result
    return result
end

function Perception.nearbySurvivors(origin, radius)
    return nearbyFrom(Perception.state.survivors, origin, radius)
end

function Perception.nearbyZombies(origin, radius)
    return nearbyFrom(Perception.state.zombies, origin, radius)
end

function Perception.nearbyPlayers(origin, radius)
    return nearbyFrom(Perception.state.players, origin, radius)
end

function Perception.allZombies()
    return Perception.state.zombieList
end

function Perception.allSurvivors()
    return Perception.state.survivorList
end

function Perception.allPlayers()
    return Perception.state.playerList
end

function Perception.survivorById(id)
    if type(id) ~= "string" then return nil end
    for _, survivor in ipairs(Perception.state.survivorList) do
        if Identity.getId(survivor) == id then return survivor end
    end
    return nil
end

function Perception.nearestPlayer(origin, radius)
    local point = type(origin) == "table" and origin.x ~= nil
        and origin or Perception.position(origin)
    local nearest, nearestDistance = nil, math.huge
    for _, player in ipairs(Perception.nearbyPlayers(point, radius or 30)) do
        local value = distanceSquared(point, Perception.position(player))
        if value < nearestDistance then nearest, nearestDistance = player, value end
    end
    return nearest, nearestDistance
end

function Perception.playerByName(name)
    if type(name) ~= "string" then return nil end
    local wanted = string.lower(name)
    -- Name lookup is global over the bounded online-player list. Do not turn
    -- this into a world-radius bucket query: a huge radius would enumerate
    -- millions of empty buckets before finding the same small player list.
    for _, player in ipairs(Perception.allPlayers()) do
        if type(player.getUsername) == "function" then
            local ok, username = pcall(function() return player:getUsername() end)
            if ok and type(username) == "string" and string.lower(username) == wanted then
                return player
            end
        end
    end
    -- A name lookup should still work when the requested player is outside
    -- the current cache radius; the online collection is a bounded list.
    local players = onlinePlayers()
    local found = nil
    eachCollection(players, function(player)
        if found == nil and type(player.getUsername) == "function" then
            local ok, username = pcall(function() return player:getUsername() end)
            if ok and type(username) == "string" and string.lower(username) == wanted then
                found = player
            end
        end
    end)
    return found
end

function Perception.nearestThreat(origin, radius)
    local point = type(origin) == "table" and origin.x ~= nil
        and origin or Perception.position(origin)
    local nearest, nearestDistance = nil, math.huge
    for _, zombie in ipairs(Perception.nearbyZombies(point, radius or 32)) do
        local value = distanceSquared(point, Perception.position(zombie))
        if value < nearestDistance then nearest, nearestDistance = zombie, value end
    end
    return nearest, nearestDistance
end

function Perception.threats(origin, radius)
    return Perception.nearbyZombies(origin, radius or 32)
end

function Perception.stats()
    local count = 0
    for _, bucket in pairs(Perception.state.survivors) do count = count + #bucket end
    return {
        generation = Perception.state.generation,
        survivor_count = count,
        scans = Perception.state.scans,
        candidates = Perception.state.candidates,
        refresh_interval_ms = Perception.refreshIntervalMs,
        bucket_size = Perception.bucketSize
    }
end

return Perception
