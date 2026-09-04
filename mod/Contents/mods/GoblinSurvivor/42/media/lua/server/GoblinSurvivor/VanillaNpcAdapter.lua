-- Original, dependency-free NPC body adapter.
--
-- Build 42 exposes networked zombie creation and movement to server Lua.  We
-- use that public surface as the transportable body and keep Goblin identity,
-- protection, tasks, and persistence in this mod's own data.  No Workshop
-- framework code or globals are required here.
local Config = require("GoblinSurvivor/Config")

local VanillaNpcAdapter = {}

local function functionExists(owner, name)
    return owner ~= nil and type(owner[name]) == "function"
end

local function callIfPresent(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then
        return false
    end
    local ok = pcall(object[method], object, ...)
    return ok
end

local function position(object)
    if object == nil or not functionExists(object, "getX")
        or not functionExists(object, "getY") or not functionExists(object, "getZ") then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return object:getX(), object:getY(), object:getZ()
    end)
    if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

local function dataFor(body)
    if body == nil or not functionExists(body, "getModData") then
        return nil
    end
    local ok, data = pcall(function() return body:getModData() end)
    return ok and type(data) == "table" and data or nil
end

local function firstValue(values)
    if values == nil then return nil end
    if type(values.size) == "function" and type(values.get) == "function" then
        local okSize, size = pcall(function() return values:size() end)
        if okSize and type(size) == "number" and size > 0 then
            local okValue, value = pcall(function() return values:get(0) end)
            return okValue and value or nil
        end
        return nil
    end
    return values[1]
end

local function eachOnlinePlayer(callback)
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
    if type(label) ~= "string" or label == "" then return nil end
    local wanted = string.lower(label)
    local result = nil
    eachOnlinePlayer(function(player)
        if result ~= nil then return end
        if functionExists(player, "getUsername") then
            local ok, username = pcall(function() return player:getUsername() end)
            if ok and type(username) == "string" and string.lower(username) == wanted then
                result = player
            end
        end
    end)
    return result
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function pathTo(body, x, y, z)
    if body == nil then return false, "NPC body is missing" end
    if functionExists(body, "pathToLocationF") then
        local ok = pcall(body.pathToLocationF, body, x, y, z)
        if ok then return true, "path request accepted" end
    end
    if functionExists(body, "pathToLocation") then
        local ok = pcall(body.pathToLocation, body, math.floor(x), math.floor(y), math.floor(z))
        if ok then return true, "path request accepted" end
    end
    return false, "vanilla NPC movement API is unavailable"
end

function VanillaNpcAdapter.available()
    -- This is a documented server Lua global in Build 42.  It creates a
    -- normal networked IsoZombie, which is the body class clients already
    -- know how to receive.  The mod adds its own identity and policy data.
    return type(addZombiesInOutfit) == "function"
end

function VanillaNpcAdapter.capabilities()
    return {
        available = VanillaNpcAdapter.available(),
        spawnIndividual = type(addZombiesInOutfit) == "function",
        networkedBody = "IsoZombie",
        movement = type(IsoGameCharacter) == "table"
            or type(IsoZombie) == "table",
        speech = true,
        restore = false,
        externalFramework = false
    }
end

function VanillaNpcAdapter.isOwned(body)
    local data = dataFor(body)
    return data ~= nil
        and data.goblin_npc_id == Config.npcId
        and data.goblin_owned == true
end

function VanillaNpcAdapter.prepare(body, npcId)
    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end
    data.goblin_npc_id = npcId or Config.npcId
    data.goblin_owned = true
    data.goblin_engine = "vanilla-zombie"
    data.goblin_protected = true
    data.goblin_task = nil
    data.goblin_next_path_at = nil

    -- These are all guarded because minor Build 42 updates can change which
    -- engine hooks are exposed to server Lua.  The data marker remains the
    -- authoritative ownership check used by the registry.
    callIfPresent(body, "setNoDamage", true)
    callIfPresent(body, "setTarget", nil)
    callIfPresent(body, "setUseless", true)
    callIfPresent(body, "setDisplayName", Config.npcName)
    return true, "vanilla NPC prepared"
end

function VanillaNpcAdapter.spawnIndividual(anchor, npcId, _program)
    if not VanillaNpcAdapter.available() then
        return false, "vanilla server NPC spawn API is unavailable", nil
    end
    local point = position(anchor)
    if point == nil then
        return false, "online player anchor has no position", nil
    end

    local x, y, z = math.floor(point.x), math.floor(point.y), math.floor(point.z)
    -- The long overload asks the engine for an invulnerable, standing body.
    -- prepare() repeats the safety hooks after creation for runtimes that do
    -- not honor every optional argument.
    local ok, spawned = pcall(
        addZombiesInOutfit,
        x, y, z, 1, "Survivor", 50,
        false, false, false, false, true, false, 1.0
    )
    if not ok then
        -- Keep compatibility with runtimes exposing only the short overload.
        ok, spawned = pcall(addZombiesInOutfit, x, y, z, 1, "Survivor", 50)
    end
    if not ok then
        return false, "vanilla server NPC spawn failed", nil
    end
    local body = firstValue(spawned)
    if body == nil then
        return false, "vanilla server NPC spawn returned no body", nil
    end
    local prepared, detail = VanillaNpcAdapter.prepare(body, npcId)
    if not prepared then return false, detail, nil end
    return true, "vanilla NPC spawned", body
end

function VanillaNpcAdapter.getBrain(body)
    -- The own mod-data table is the deliberate replacement for a foreign
    -- framework brain.  Callers only use it for local, bounded task state.
    return dataFor(body)
end

function VanillaNpcAdapter.setTasks(body, tasks)
    if not VanillaNpcAdapter.isOwned(body) or type(tasks) ~= "table" then
        return false, "vanilla NPC task contract is unavailable"
    end
    local task = tasks[1]
    if type(task) ~= "table" or task.action ~= "GoTo"
        or type(task.x) ~= "number" or type(task.y) ~= "number"
        or type(task.z) ~= "number" then
        return false, "vanilla NPC task is malformed"
    end
    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end
    data.goblin_task = {
        mode = task.mode or "MOVE_TO",
        x = task.x,
        y = task.y,
        z = task.z,
        target_player = task.target_player
    }
    data.goblin_next_path_at = 0
    return pathTo(body, task.x, task.y, task.z)
end

function VanillaNpcAdapter.clearTasks(body)
    if not VanillaNpcAdapter.isOwned(body) then
        return false, "vanilla NPC task contract is unavailable"
    end
    local data = dataFor(body)
    if data ~= nil then
        data.goblin_task = nil
        data.goblin_next_path_at = nil
    end
    callIfPresent(body, "setTarget", nil)
    return true, "tasks cleared"
end

function VanillaNpcAdapter.tick(body)
    if not VanillaNpcAdapter.isOwned(body) then return false end

    -- A friendly body must never retain the vanilla zombie aggro target.  The
    -- explicit combat action remains a separate, future capability.
    callIfPresent(body, "setTarget", nil)
    callIfPresent(body, "setUseless", true)

    local data = dataFor(body)
    local task = data and data.goblin_task or nil
    if type(task) ~= "table" then return true end

    if type(task.target_player) == "string" and task.target_player ~= "" then
        local player = playerFor(task.target_player)
        local playerPoint = position(player)
        if playerPoint == nil then
            data.goblin_task = nil
            data.goblin_next_path_at = nil
            return false
        end
        task.x, task.y, task.z = playerPoint.x, playerPoint.y, playerPoint.z
    end

    local nextAt = tonumber(data.goblin_next_path_at) or 0
    if nowMs() >= nextAt then
        local ok = pathTo(body, task.x, task.y, task.z)
        data.goblin_next_path_at = nowMs() + 1000
        return ok
    end
    return true
end

return VanillaNpcAdapter
