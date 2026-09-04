-- Bandits2-backed body adapter.
--
-- This is the only GoblinSurvivor module that knows Bandits' Lua surface.
-- The higher-level registry and command code use the small NpcAdapter
-- contract instead of reaching into a Workshop framework directly.
local Config = require("GoblinSurvivor/Config")

local BanditsAdapter = {}

local clanId = "goblin_survivor"
local defaultProgram = "Companion"

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function functionExists(owner, name)
    return owner ~= nil and type(owner[name]) == "function"
end

local function invoke(owner, name, ...)
    if not functionExists(owner, name) then
        return false, nil
    end
    local ok, first, second, third = pcall(owner[name], ...)
    return ok, first, second, third
end

local function position(object)
    if object == nil or not functionExists(object, "getX")
        or not functionExists(object, "getY") or not functionExists(object, "getZ") then
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

local function dataFor(body)
    if body == nil or not functionExists(body, "getModData") then
        return nil
    end
    local ok, data = pcall(function() return body:getModData() end)
    return ok and type(data) == "table" and data or nil
end

local function eachZombie(callback)
    if type(getCell) ~= "function" then return end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil or not functionExists(cell, "getZombieList") then
        return
    end
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

local function distanceSquared(a, b)
    if a == nil or b == nil then return math.huge end
    local dx = (a.x or 0) - (b.x or 0)
    local dy = (a.y or 0) - (b.y or 0)
    local dz = (a.z or 0) - (b.z or 0)
    return dx * dx + dy * dy + dz * dz
end

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] Bandits2: " .. tostring(message))
    end
end

local function apisReady()
    local server = rawget(_G, "BanditServer")
    local spawner = server and server.Spawner
    local brain = rawget(_G, "BanditBrain")
    local custom = rawget(_G, "BanditCustom")
    return type(spawner) == "table"
        and functionExists(spawner, "Individual")
        and type(brain) == "table"
        and functionExists(brain, "Get")
        and functionExists(brain, "Update")
        and type(custom) == "table"
        and functionExists(custom, "Load")
        and functionExists(custom, "Save")
        and functionExists(custom, "ClanGet")
        and functionExists(custom, "ClanCreate")
        and functionExists(custom, "GetById")
        and functionExists(custom, "Create")
end

function BanditsAdapter.available()
    return apisReady() and type(addZombiesInOutfit) == "function"
end

function BanditsAdapter.engineName()
    return "bandits2"
end

function BanditsAdapter.capabilities()
    local ready = BanditsAdapter.available()
    return {
        available = ready,
        friendly = ready,
        spawnIndividual = ready,
        networkedBody = "Bandits2/IsoZombie",
        movement = ready,
        speech = true,
        restore = false,
        externalFramework = true,
        framework = "Bandits2",
        workshop_id = "3268487204"
    }
end

local function bodyBrain(body)
    local brain = rawget(_G, "BanditBrain")
    if type(brain) ~= "table" or not functionExists(brain, "Get") then
        return nil
    end
    local ok, result = invoke(brain, "Get", body)
    return ok and type(result) == "table" and result or nil
end

local function characterId(player)
    local utils = rawget(_G, "BanditUtils")
    if player ~= nil and type(utils) == "table"
        and functionExists(utils, "GetCharacterID") then
        local ok, result = invoke(utils, "GetCharacterID", player)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end
    if player ~= nil and functionExists(player, "getUsername") then
        local ok, result = pcall(function() return player:getUsername() end)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end
    return nil
end

local function setSafeBodyHooks(body)
    if body == nil then return end
    if functionExists(body, "setNoDamage") then
        pcall(body.setNoDamage, body, true)
    end
    if functionExists(body, "setImmortal") then
        pcall(body.setImmortal, body, true)
    end
    if functionExists(body, "setTarget") then
        pcall(body.setTarget, body, nil)
    end
    if functionExists(body, "setDisplayName") then
        pcall(body.setDisplayName, body, Config.npcName)
    end
    if functionExists(body, "transmitModData") then
        pcall(body.transmitModData, body)
    end
end

local function ensureProfile(npcId)
    if not BanditsAdapter.available() then
        return false, "Bandits2 server API is unavailable"
    end
    local okLoad = invoke(BanditCustom, "Load")
    if not okLoad then
        return false, "Bandits2 custom profile load failed"
    end

    local okClan, clan = invoke(BanditCustom, "ClanGet", clanId)
    if not okClan then
        return false, "Bandits2 clan lookup failed"
    end
    if clan == nil then
        local created, result = invoke(BanditCustom, "ClanCreate", clanId)
        if not created or type(result) ~= "table" then
            return false, "Bandits2 clan creation failed"
        end
        clan = result
    end
    if type(clan.spawn) ~= "table" then clan.spawn = {} end
    if type(clan.general) ~= "table" then clan.general = {} end
    clan.general.name = Config.npcName
    -- Bandits derives both hostile flags from this clan value before applying
    -- explicit spawn args. Keep it persisted so future framework restores
    -- remain friendly too.
    clan.spawn.friendly = true
    clan.spawn.companion = true
    clan.spawn.assault = false
    clan.spawn.defenders = false
    clan.spawn.campers = false
    clan.spawn.wanderer = false
    clan.spawn.roadblock = false
    clan.spawn.spawnChance = 0

    local okProfile, profile = invoke(BanditCustom, "GetById", npcId)
    if not okProfile then
        return false, "Bandits2 NPC profile lookup failed"
    end
    if profile == nil then
        local created, result = invoke(BanditCustom, "Create", npcId)
        if not created or type(result) ~= "table" then
            return false, "Bandits2 NPC profile creation failed"
        end
        profile = result
    end
    if type(profile.general) ~= "table" then profile.general = {} end
    if type(profile.clothing) ~= "table" then profile.clothing = {} end
    if type(profile.tint) ~= "table" then profile.tint = {} end
    if type(profile.weapons) ~= "table" then profile.weapons = {} end
    if type(profile.ammo) ~= "table" then profile.ammo = {} end
    if type(profile.bag) ~= "table" then profile.bag = {} end
    profile.general.name = Config.npcName
    profile.general.cid = clanId
    profile.general.bid = npcId
    profile.general.female = false
    profile.general.health = 5

    local okSave = invoke(BanditCustom, "Save")
    if not okSave then
        return false, "Bandits2 custom profile save failed"
    end
    return true, "friendly Bandits2 profile ready"
end

local function profileBrainMatches(body, npcId)
    local brain = bodyBrain(body)
    return brain ~= nil and brain.bid == npcId and brain.cid == clanId
end

function BanditsAdapter.isCandidate(body)
    return BanditsAdapter.available() and profileBrainMatches(body, Config.npcId)
end

function BanditsAdapter.isFriendly(body)
    local brain = bodyBrain(body)
    return brain ~= nil
        and brain.bid == Config.npcId
        and brain.cid == clanId
        and brain.hostile == false
        and brain.hostileP == false
        and brain.loyal == true
        and brain.permanent == true
end

function BanditsAdapter.isOwned(body)
    local data = dataFor(body)
    return BanditsAdapter.isFriendly(body)
        and data ~= nil
        and data.goblin_npc_id == Config.npcId
        and data.goblin_owned == true
        and data.goblin_friendly == true
end

function BanditsAdapter.prepare(body, npcId, anchor)
    if not BanditsAdapter.available() then
        return false, "Bandits2 server API is unavailable"
    end
    if not profileBrainMatches(body, npcId or Config.npcId) then
        return false, "body is not the Goblin Bandits2 profile"
    end
    local brain = bodyBrain(body)
    if brain == nil then return false, "Bandits2 brain is unavailable" end
    brain.hostile = false
    brain.hostileP = false
    brain.loyal = true
    brain.permanent = true
    brain.program = type(brain.program) == "table" and brain.program or {}
    brain.program.name = defaultProgram
    brain.program.stage = brain.program.stage or "Prepare"
    brain.programFallback = defaultProgram
    local master = characterId(anchor)
    if master ~= nil then brain.master = master end

    local okUpdate = invoke(BanditBrain, "Update", body, brain)
    if not okUpdate then return false, "Bandits2 brain update failed" end
    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end
    data.goblin_npc_id = npcId or Config.npcId
    data.goblin_owned = true
    data.goblin_friendly = true
    data.goblin_engine = BanditsAdapter.engineName()
    data.goblin_protected = true
    data.goblin_task = nil
    data.goblin_next_path_at = nil
    setSafeBodyHooks(body)
    if not BanditsAdapter.isFriendly(body) then
        return false, "Bandits2 did not retain friendly brain state"
    end
    return true, "friendly Bandits2 NPC prepared"
end

local function nearbyCandidate(point)
    local result = nil
    eachZombie(function(zombie)
        if result ~= nil then return end
        local candidatePoint = position(zombie)
        if candidatePoint ~= nil and distanceSquared(candidatePoint, point) <= 4096
            and BanditsAdapter.isCandidate(zombie) then
            result = zombie
        end
    end)
    return result
end

function BanditsAdapter.spawnPoint(anchor)
    local point = position(anchor)
    if point == nil then return nil end
    local offset = tonumber(Config.npcSpawnOffsetTiles) or 16
    if offset < 8 then offset = 8 end
    return {
        x = math.floor(point.x + offset),
        y = math.floor(point.y + offset),
        z = math.floor(point.z)
    }
end

function BanditsAdapter.spawnIndividual(anchor, npcId, program)
    if not BanditsAdapter.available() then
        return false, "friendly Bandits2 server API is unavailable", nil
    end
    local profileOk, profileDetail = ensureProfile(npcId or Config.npcId)
    if not profileOk then
        log(profileDetail)
        return false, profileDetail, nil
    end
    local spawnPoint = BanditsAdapter.spawnPoint(anchor)
    if spawnPoint == nil then
        return false, "online player anchor has no spawn point", nil
    end
    local requestedProgram = type(program) == "string" and program or ""
    if requestedProgram == "" or requestedProgram == "VanillaZombie" then
        requestedProgram = defaultProgram
    end
    local args = {
        bid = npcId or Config.npcId,
        x = spawnPoint.x,
        y = spawnPoint.y,
        z = spawnPoint.z,
        program = requestedProgram,
        permanent = true,
        loyal = true,
        hostile = false,
        hostileP = false
    }
    log("requesting one friendly individual through Bandits2")
    local okSpawn = invoke(BanditServer.Spawner, "Individual", anchor, args)
    if not okSpawn then
        return false, "Bandits2 individual spawn failed", nil, spawnPoint
    end

    -- The public wrapper returns no body. It creates and banditizes the body
    -- during the call, so scan only for this exact profile and never claim a
    -- normal zombie as Goblin.
    local body = nearbyCandidate(spawnPoint)
    if body ~= nil then
        local prepared, detail = BanditsAdapter.prepare(body, npcId, anchor)
        if prepared then
            return true, detail, body, spawnPoint
        end
        return false, detail, nil, spawnPoint
    end
    return true, "Bandits2 spawn submitted; awaiting profile bind", nil, spawnPoint
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
    return false, "Bandits2 movement API is unavailable"
end

local function updateFriendlyBrain(body, targetPlayer)
    local brain = bodyBrain(body)
    if brain == nil then return false end
    local changed = false
    if brain.hostile ~= false then brain.hostile = false; changed = true end
    if brain.hostileP ~= false then brain.hostileP = false; changed = true end
    if brain.loyal ~= true then brain.loyal = true; changed = true end
    if brain.permanent ~= true then brain.permanent = true; changed = true end
    if type(brain.program) ~= "table" then brain.program = {}; changed = true end
    if brain.program.name ~= defaultProgram then brain.program.name = defaultProgram; changed = true end
    if brain.program.stage == nil then brain.program.stage = "Prepare"; changed = true end
    if brain.programFallback ~= defaultProgram then
        brain.programFallback = defaultProgram
        changed = true
    end
    if targetPlayer ~= nil then
        local master = characterId(targetPlayer)
        if master ~= nil and brain.master ~= master then
            brain.master = master
            changed = true
        end
    end
    if changed then
        local ok = invoke(BanditBrain, "Update", body, brain)
        if not ok then return false end
    end
    return BanditsAdapter.isFriendly(body)
end

function BanditsAdapter.getBrain(body)
    return bodyBrain(body)
end

function BanditsAdapter.setTasks(body, tasks)
    if not BanditsAdapter.isOwned(body) or type(tasks) ~= "table" then
        return false, "friendly Bandits2 NPC task contract is unavailable"
    end
    local task = tasks[1]
    if type(task) ~= "table" or task.action ~= "GoTo"
        or type(task.x) ~= "number" or type(task.y) ~= "number"
        or type(task.z) ~= "number" then
        return false, "Bandits2 NPC task is malformed"
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
    if not updateFriendlyBrain(body, nil) then
        return false, "Bandits2 friendly brain state could not be enforced"
    end
    return pathTo(body, task.x, task.y, task.z)
end

function BanditsAdapter.clearTasks(body)
    if not BanditsAdapter.isOwned(body) then
        return false, "friendly Bandits2 NPC task contract is unavailable"
    end
    local data = dataFor(body)
    if data ~= nil then
        data.goblin_task = nil
        data.goblin_next_path_at = nil
    end
    if functionExists(body, "setTarget") then
        pcall(body.setTarget, body, nil)
    end
    updateFriendlyBrain(body, nil)
    return true, "tasks cleared"
end

local function playerFor(label)
    if type(label) ~= "string" or label == ""
        or type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return nil end
    local count = type(players.size) == "function" and players:size() or #players
    local wanted = string.lower(label)
    for index = 0, count - 1 do
        local player = type(players.get) == "function"
            and players:get(index) or players[index + 1]
        if player ~= nil and functionExists(player, "getUsername") then
            local okName, username = pcall(function() return player:getUsername() end)
            if okName and type(username) == "string"
                and string.lower(username) == wanted then
                return player
            end
        end
    end
    return nil
end

function BanditsAdapter.tick(body)
    if not BanditsAdapter.isOwned(body) then return false end
    if not updateFriendlyBrain(body, nil) then return false end
    if functionExists(body, "setTarget") then
        pcall(body.setTarget, body, nil)
    end
    local data = dataFor(body)
    local task = data and data.goblin_task or nil
    if type(task) ~= "table" then return true end
    local targetPlayer = nil
    if type(task.target_player) == "string" and task.target_player ~= "" then
        targetPlayer = playerFor(task.target_player)
        local targetPoint = position(targetPlayer)
        if targetPoint == nil then
            data.goblin_task = nil
            data.goblin_next_path_at = nil
            return false
        end
        task.x, task.y, task.z = targetPoint.x, targetPoint.y, targetPoint.z
        updateFriendlyBrain(body, targetPlayer)
    end
    local now = nowMs()
    local nextAt = tonumber(data.goblin_next_path_at) or 0
    if now >= nextAt then
        local ok = pathTo(body, task.x, task.y, task.z)
        data.goblin_next_path_at = now + 1000
        return ok
    end
    return true
end

return BanditsAdapter
