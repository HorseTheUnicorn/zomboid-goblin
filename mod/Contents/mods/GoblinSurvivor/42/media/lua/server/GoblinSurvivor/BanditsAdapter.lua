-- Bandits2-backed body adapter.
--
-- This is the only GoblinSurvivor module that knows Bandits2's Lua surface.
-- Bandits2 owns the networked IsoZombie body and its Companion program;
-- GoblinSurvivor owns Goblin identity, safety, command policy, chat, and
-- persistence through the small NpcAdapter contract.
local Config = require("GoblinSurvivor/Config")

local BanditsAdapter = {}

local clanId = "goblin_survivor"
local defaultProgram = "Companion"
local combatTargets = {}
local ownedBodies = {}

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

-- Bandits2 exposes plain module functions, not colon methods.  Keep the
-- protected call in one place so a minor Workshop update fails closed instead
-- of breaking the server bootstrap.
local function invoke(owner, name, ...)
    if not functionExists(owner, name) then
        return false, nil
    end
    local ok, first, second, third = pcall(owner[name], ...)
    return ok, first, second, third
end

local function callIfPresent(object, method, ...)
    if object == nil or not functionExists(object, method) then
        return false
    end
    return pcall(object[method], object, ...)
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
    local utils = rawget(_G, "BanditUtils")
    local compatibility = rawget(_G, "BanditCompatibility")
    local bandit = rawget(_G, "Bandit")
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
        and type(utils) == "table"
        and functionExists(utils, "GetCharacterID")
        and type(compatibility) == "table"
        and functionExists(compatibility, "AddZombiesInOutfit")
        and type(bandit) == "table"
        and functionExists(bandit, "UpdateTask")
        and functionExists(bandit, "ClearTasks")
end

function BanditsAdapter.available()
    -- Do not check the vanilla addZombiesInOutfit global here. Bandits2's
    -- public individual-spawn path uses BanditCompatibility.AddZombiesInOutfit
    -- and is the only body creation path GoblinSurvivor is allowed to use.
    return apisReady()
end

function BanditsAdapter.engineName()
    return "bandits2"
end

function BanditsAdapter.capabilities()
    local ready = BanditsAdapter.available()
    return {
        available = ready,
        control_ready = ready,
        friendly = ready,
        spawnIndividual = ready,
        networkedBody = "Bandits2/IsoZombie",
        movement = ready,
        speech = true,
        restore = false,
        externalFramework = true,
        framework = "Bandits2",
        workshop_id = "3268487204",
        program = defaultProgram,
        combat = ready and "bounded_zombie_target" or "unavailable"
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
        if ok and (type(result) == "string" or type(result) == "number")
            and tostring(result) ~= "" then
            return tostring(result)
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

local function setSafeBodyHooks(body, displayName, protectedBody)
    if body == nil then return end
    -- Only the primary Goblin receives the protected/immortal policy. Other
    -- bodies are still friendly Bandits2 companions, but remain ordinary
    -- survivable NPCs so a follower can be incapacitated or die normally.
    if protectedBody then
        if functionExists(body, "setNoDamage") then
            pcall(body.setNoDamage, body, true)
        end
        if functionExists(body, "setImmortal") then
            pcall(body.setImmortal, body, true)
        end
        if functionExists(body, "setImmortalTutorialZombie") then
            pcall(body.setImmortalTutorialZombie, body, true)
        end
    end
    if functionExists(body, "setTarget") then
        pcall(body.setTarget, body, nil)
    end
    if functionExists(body, "setDisplayName") then
        pcall(body.setDisplayName, body, displayName or Config.npcName)
    end
    if functionExists(body, "transmitModData") then
        pcall(body.transmitModData, body)
    end
end

local function ensureProfile(npcId, displayName)
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
    clan.general.name = "GoblinSurvivor Friends"
    -- Persist a non-hostile, companion-only clan. Explicit spawn arguments
    -- below repeat these values so a framework reload cannot change policy.
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
    profile.general.name = displayName or Config.npcName
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
    return brain ~= nil and brain.bid == (npcId or Config.npcId)
        and brain.cid == clanId
end

function BanditsAdapter.isCandidate(body, npcId)
    local requestedId = npcId or Config.npcId
    return BanditsAdapter.available()
        and profileBrainMatches(body, requestedId)
end

-- A normal population zombie must never be claimed by OnZombieCreate. The
-- Bandits2 wrapper may emit that event before it finishes banditizing its new
-- body, so the registry will use its bounded profile scan afterward.
function BanditsAdapter.isEventCandidate(body, npcId)
    return BanditsAdapter.isCandidate(body, npcId)
end

function BanditsAdapter.isFriendly(body, npcId)
    local requestedId = npcId or Config.npcId
    local brain = bodyBrain(body)
    return brain ~= nil
        and brain.bid == requestedId
        and brain.cid == clanId
        and brain.hostile == false
        and brain.hostileP == false
        and brain.loyal == true
        and brain.permanent == true
end

function BanditsAdapter.isOwned(body, npcId)
    local requestedId = npcId or Config.npcId
    local data = dataFor(body)
    return BanditsAdapter.isFriendly(body, requestedId)
        and data ~= nil
        and data.goblin_npc_id == requestedId
        and data.goblin_owned == true
        and data.goblin_friendly == true
end

local function enforceFriendlyBrain(body, targetPlayer, resetStage, npcId)
    local requestedId = npcId or Config.npcId
    local brain = bodyBrain(body)
    if brain == nil then return false end
    local changed = false
    if brain.hostile ~= false then brain.hostile = false; changed = true end
    if brain.hostileP ~= false then brain.hostileP = false; changed = true end
    if brain.loyal ~= true then brain.loyal = true; changed = true end
    if brain.permanent ~= true then brain.permanent = true; changed = true end
    if type(brain.program) ~= "table" then brain.program = {}; changed = true end
    if brain.program.name ~= defaultProgram then
        brain.program.name = defaultProgram
        changed = true
    end
    if resetStage and brain.program.stage ~= "Prepare" then
        brain.program.stage = "Prepare"
        changed = true
    elseif brain.program.stage == nil then
        brain.program.stage = "Prepare"
        changed = true
    end
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
        local okUpdate = invoke(BanditBrain, "Update", body, brain)
        if not okUpdate then return false end
    end
    return BanditsAdapter.isFriendly(body, requestedId)
end

function BanditsAdapter.prepare(body, npcId, anchor, displayName, role)
    if not BanditsAdapter.available() then
        return false, "Bandits2 server API is unavailable"
    end
    local requestedId = npcId or Config.npcId
    if not profileBrainMatches(body, requestedId) then
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
    brain.program.stage = "Prepare"
    brain.programFallback = defaultProgram
    local master = characterId(anchor)
    if master ~= nil then brain.master = master end

    local okUpdate = invoke(BanditBrain, "Update", body, brain)
    if not okUpdate then return false, "Bandits2 brain update failed" end

    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end
    data.goblin_npc_id = requestedId
    data.goblin_owned = true
    data.goblin_friendly = true
    data.goblin_engine = BanditsAdapter.engineName()
    data.goblin_display_name = displayName or Config.npcName
    data.goblin_role = role or (requestedId == Config.npcId and Config.npcRole or "companion")
    data.goblin_protected = requestedId == Config.npcId
    data.goblin_task = nil
    data.goblin_combat = false
    data.goblin_next_path_at = nil
    combatTargets[body] = nil
    ownedBodies[requestedId] = body
    setSafeBodyHooks(body, data.goblin_display_name, data.goblin_protected)
    if not BanditsAdapter.isFriendly(body, requestedId) then
        return false, "Bandits2 did not retain friendly brain state"
    end
    return true, "friendly Bandits2 NPC prepared"
end

local function nearbyCandidate(point, npcId)
    local result = nil
    eachZombie(function(zombie)
        if result ~= nil then return end
        local candidatePoint = position(zombie)
        if candidatePoint ~= nil and distanceSquared(candidatePoint, point) <= 4096
            and BanditsAdapter.isCandidate(zombie, npcId) then
            result = zombie
        end
    end)
    return result
end

function BanditsAdapter.spawnPoint(anchor, extraOffset)
    local point = position(anchor)
    if point == nil then return nil end
    local offset = tonumber(extraOffset) or tonumber(Config.npcSpawnOffsetTiles) or 16
    if offset < 8 then offset = 8 end
    return {
        x = math.floor(point.x + offset),
        y = math.floor(point.y + offset),
        z = math.floor(point.z)
    }
end

function BanditsAdapter.spawnIndividual(anchor, npcId, _program, displayName, role, extraOffset)
    if not BanditsAdapter.available() then
        return false, "friendly Bandits2 server API is unavailable", nil
    end
    local requestedId = npcId or Config.npcId
    local profileOk, profileDetail = ensureProfile(requestedId, displayName)
    if not profileOk then
        log(profileDetail)
        return false, profileDetail, nil
    end
    local spawnPoint = BanditsAdapter.spawnPoint(anchor, extraOffset)
    if spawnPoint == nil then
        return false, "online player anchor has no spawn point", nil
    end

    -- Companion is the verified Bandits2 program for a friendly body. Do not
    -- pass arbitrary config text into the Workshop framework.
    local args = {
        bid = requestedId,
        x = spawnPoint.x,
        y = spawnPoint.y,
        z = spawnPoint.z,
        program = defaultProgram,
        permanent = true,
        loyal = true,
        hostile = false,
        hostileP = false
    }
    log("requesting one friendly individual through Bandits2")
    local okSpawn, result = invoke(BanditServer.Spawner, "Individual", anchor, args)
    if not okSpawn or result == false then
        return false, "Bandits2 individual spawn failed", nil, spawnPoint
    end

    -- The public wrapper returns no body. It creates and banditizes during the
    -- call, so scan only for this exact profile and never claim a normal
    -- zombie as Goblin.
    local body = nearbyCandidate(spawnPoint, requestedId)
    if body ~= nil then
        local prepared, detail = BanditsAdapter.prepare(
            body, requestedId, anchor, displayName, role
        )
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

local function isLiveTarget(target)
    if target == nil or position(target) == nil then return false end
    if functionExists(target, "isExistInTheWorld") then
        local ok, exists = pcall(function() return target:isExistInTheWorld() end)
        if ok and not exists then return false end
    end
    if functionExists(target, "isDead") then
        local ok, dead = pcall(function() return target:isDead() end)
        if ok and dead then return false end
    end
    if functionExists(target, "isPlayer") then
        local ok, isPlayer = pcall(function() return target:isPlayer() end)
        if ok and isPlayer then return false end
    end
    local data = dataFor(target)
    return data == nil or (data.goblin_owned ~= true and data.goblin_friendly ~= true)
end

local function installMoveTask(body, task, targetPlayer, targetBody)
    local brain = bodyBrain(body)
    local utils = rawget(_G, "BanditUtils")
    local bandit = rawget(_G, "Bandit")
    if brain == nil or type(utils) ~= "table" or type(bandit) ~= "table" then
        return false, "Bandits2 movement helpers are unavailable"
    end
    local endurance = tonumber(brain.endurance) or 0
    -- Bandits2's verified target helper accepts a stopping distance. Keep
    -- companions a few squares away so squads do not collapse onto a leader.
    local distance = tonumber(task.follow_distance) or 2
    local walkType = (task.mode == "RETREAT" or task.mode == "FLEE")
        and "Run" or "Walk"
    local moveTask = nil
    if targetPlayer ~= nil and functionExists(utils, "GetMoveTaskTarget") then
        local targetId = characterId(targetPlayer)
        if targetId ~= nil then
            local ok, result = invoke(utils, "GetMoveTaskTarget", endurance,
                task.x, task.y, task.z, targetId, true, walkType, distance)
            if ok and type(result) == "table" then moveTask = result end
        end
    end
    if moveTask == nil and targetBody ~= nil
        and functionExists(utils, "GetMoveTaskTarget") then
        local targetId = characterId(targetBody)
        if targetId ~= nil then
            local ok, result = invoke(utils, "GetMoveTaskTarget", endurance,
                task.x, task.y, task.z, targetId, false, walkType, distance)
            if ok and type(result) == "table" then moveTask = result end
        end
    end
    if moveTask == nil and functionExists(utils, "GetMoveTask") then
        local ok, result = invoke(utils, "GetMoveTask", endurance,
            task.x, task.y, task.z, walkType, distance, false)
        if ok and type(result) == "table" then moveTask = result end
    end
    if moveTask == nil then
        return pathTo(body, task.x, task.y, task.z)
    end
    local okUpdate = invoke(bandit, "UpdateTask", body, moveTask)
    if not okUpdate then return false, "Bandits2 movement task update failed" end
    local currentBrain = bodyBrain(body)
    if currentBrain == nil or not invoke(BanditBrain, "Update", body, currentBrain) then
        return false, "Bandits2 movement brain update failed"
    end
    return true, "Bandits2 movement task accepted"
end

function BanditsAdapter.getBrain(body)
    return bodyBrain(body)
end

-- Bandits2's public Bandit.Say function is a canned-phrase/sound helper: it
-- looks up a key in Bandit.SoundTab. Goblin speech is arbitrary, bounded
-- text produced by the private Python service, so use the same networked
-- body's verified chat-line primitive instead of pretending a Qwen sentence
-- is a Bandits sound key. This is the only framework-specific speech detail
-- exposed to the rest of GoblinSurvivor.
function BanditsAdapter.say(body, text, npcId)
    if not BanditsAdapter.isOwned(body, npcId) then
        return false, "friendly Bandits2 NPC speech contract is unavailable"
    end
    if type(text) ~= "string" or #text < 1 or #text > 240 then
        return false, "NPC speech is malformed"
    end
    if functionExists(body, "addLineChatElement") then
        local ok = pcall(body.addLineChatElement, body, text, 0.1, 0.8, 0.1)
        if ok then return true, "speech accepted by Bandits2 body" end
    end
    return false, "Bandits2 body chat-line API is unavailable"
end

local function modeFor(data, brain)
    if data ~= nil and data.goblin_combat == true then
        return "HUNT"
    end
    local task = data ~= nil and data.goblin_task or nil
    if type(task) == "table" then
        local mode = string.upper(tostring(task.mode or ""))
        if mode == "FOLLOW" or mode == "FOLLOW_GOBLIN"
            or type(task.target_player) == "string"
            or type(task.target_npc_id) == "string" then
            return "PARTY"
        end
    end
    -- Companion's own behavior follows this stable Bandits2 master link when
    -- no explicit GoblinSurvivor task is active.
    if brain ~= nil and brain.master ~= nil then
        return "PARTY"
    end
    return "ROAM"
end

function BanditsAdapter.status(body, npcId)
    if not BanditsAdapter.isOwned(body, npcId) then
        return {
            mode = "SAFE",
            task = nil,
            target_player = nil,
            target_npc_id = nil,
            friendly = false,
            protected = false,
            needs_disabled = false,
            weapon_ready = false,
            has_food = false,
            has_water = false,
            has_medical = false
        }
    end
    local data = dataFor(body)
    local brain = bodyBrain(body)
    local task = data ~= nil and data.goblin_task or nil
    return {
        mode = modeFor(data, brain),
        task = type(task) == "table" and task.mode or nil,
        target_player = type(task) == "table" and task.target_player or nil,
        target_npc_id = type(task) == "table" and task.target_npc_id or nil,
        friendly = BanditsAdapter.isFriendly(body, npcId),
        protected = data ~= nil and data.goblin_protected == true,
        needs_disabled = data ~= nil and data.goblin_needs_disabled == true,
        -- Bandits2's verified individual spawn does not expose an inventory
        -- readiness query through the adapter contract. Do not claim that an
        -- unverified weapon or consumable exists.
        weapon_ready = data ~= nil and data.goblin_weapon_ready == true,
        has_food = false,
        has_water = false,
        has_medical = false
    }
end

function BanditsAdapter.setTasks(body, tasks, npcId)
    if not BanditsAdapter.isOwned(body, npcId) or type(tasks) ~= "table" then
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
    combatTargets[body] = nil
    data.goblin_combat = false
    data.goblin_task = {
        mode = task.mode or "MOVE_TO",
        x = task.x,
        y = task.y,
        z = task.z,
        target_player = task.target_player,
        target_npc_id = task.target_npc_id,
        follow_distance = task.follow_distance
    }
    data.goblin_next_path_at = 0
    if not enforceFriendlyBrain(body, nil, false, npcId) then
        return false, "Bandits2 friendly brain state could not be enforced"
    end
    local targetPlayer = type(task.target_player) == "string"
        and playerFor(task.target_player) or nil
    local targetBody = type(task.target_npc_id) == "string"
        and ownedBodies[task.target_npc_id] or nil
    return installMoveTask(body, data.goblin_task, targetPlayer, targetBody)
end

function BanditsAdapter.clearTasks(body, npcId)
    if not BanditsAdapter.isOwned(body, npcId) then
        return false, "friendly Bandits2 NPC task contract is unavailable"
    end
    local data = dataFor(body)
    if data ~= nil then
        data.goblin_task = nil
        data.goblin_combat = false
        data.goblin_next_path_at = nil
    end
    combatTargets[body] = nil
    invoke(Bandit, "ClearTasks", body)
    if functionExists(body, "setTarget") then
        pcall(body.setTarget, body, nil)
    end
    enforceFriendlyBrain(body, nil, false, npcId)
    return true, "tasks cleared"
end

-- Bandits2's internal Companion program owns general NPC behavior. The
-- command layer is deliberately narrower: it may nominate only a live
-- non-player zombie returned by bounded semantic perception. We retain the
-- friendly brain flags and restore only this validated target after the
-- protection hook clears ordinary zombie aggro.
function BanditsAdapter.setCombatTarget(body, target, npcId)
    if not BanditsAdapter.isOwned(body, npcId) then
        return false, "friendly Bandits2 NPC combat contract is unavailable"
    end
    if not isLiveTarget(target) then
        return false, "combat target is not a live hostile zombie"
    end
    local data = dataFor(body)
    if data == nil then return false, "NPC mod-data API is unavailable" end
    data.goblin_task = nil
    data.goblin_combat = true
    data.goblin_next_path_at = 0
    combatTargets[body] = target
    if not enforceFriendlyBrain(body, nil, false, npcId) then
        combatTargets[body] = nil
        data.goblin_combat = false
        return false, "Bandits2 friendly brain state could not be enforced"
    end
    if functionExists(body, "setTarget") then
        pcall(body.setTarget, body, target)
    end
    if functionExists(body, "pathToCharacter") then
        local ok = pcall(body.pathToCharacter, body, target)
        if ok then return true, "bounded zombie combat target accepted" end
    end
    local point = position(target)
    if point ~= nil then return pathTo(body, point.x, point.y, point.z) end
    return false, "combat target has no usable position"
end

function BanditsAdapter.tick(body, npcId)
    if not BanditsAdapter.isOwned(body, npcId) then return false end
    if not enforceFriendlyBrain(body, nil, false, npcId) then return false end

    local data = dataFor(body)
    local combatTarget = combatTargets[body]
    if data ~= nil and data.goblin_combat == true and isLiveTarget(combatTarget) then
        -- Protection.apply() clears the engine target before this function.
        -- Restore only the validated hostile-zombie target, never a player or
        -- an unmarked friendly NPC.
        if functionExists(body, "setTarget") then
            pcall(body.setTarget, body, combatTarget)
        end
        local nextAt = tonumber(data.goblin_next_path_at) or 0
        if nowMs() >= nextAt then
            local ok = false
            if functionExists(body, "pathToCharacter") then
                ok = pcall(body.pathToCharacter, body, combatTarget)
            end
            if not ok then
                local point = position(combatTarget)
                if point ~= nil then ok = pathTo(body, point.x, point.y, point.z) end
            end
            data.goblin_next_path_at = nowMs() + 500
            return ok
        end
        return true
    end

    if data ~= nil and data.goblin_combat == true then
        data.goblin_combat = false
        data.goblin_next_path_at = nil
        combatTargets[body] = nil
        invoke(Bandit, "ClearTasks", body)
    end
    if functionExists(body, "setTarget") then
        pcall(body.setTarget, body, nil)
    end

    local task = data and data.goblin_task or nil
    if type(task) ~= "table" then return true end
    local targetPlayer = nil
    if type(task.target_player) == "string" and task.target_player ~= "" then
        targetPlayer = playerFor(task.target_player)
        local targetPoint = position(targetPlayer)
        if targetPoint == nil then
            data.goblin_task = nil
            data.goblin_next_path_at = nil
            invoke(Bandit, "ClearTasks", body)
            return false
        end
        task.x, task.y, task.z = targetPoint.x, targetPoint.y, targetPoint.z
        enforceFriendlyBrain(body, targetPlayer, false, npcId)
    end
    local targetBody = nil
    if type(task.target_npc_id) == "string" and task.target_npc_id ~= "" then
        targetBody = ownedBodies[task.target_npc_id]
        if not BanditsAdapter.isOwned(targetBody, task.target_npc_id) then
            targetBody = nil
        end
        local targetPoint = position(targetBody)
        if targetPoint == nil then
            data.goblin_task = nil
            data.goblin_next_path_at = nil
            invoke(Bandit, "ClearTasks", body)
            return false
        end
        task.x, task.y, task.z = targetPoint.x, targetPoint.y, targetPoint.z
    end

    local nextAt = tonumber(data.goblin_next_path_at) or 0
    if nowMs() >= nextAt then
        local ok = installMoveTask(body, task, targetPlayer, targetBody)
        data.goblin_next_path_at = nowMs() + 1000
        return ok
    end
    return true
end

function BanditsAdapter.discard(body, npcId)
    local requestedId = npcId or Config.npcId
    if body == nil or not profileBrainMatches(body, requestedId) then
        return false
    end
    combatTargets[body] = nil
    if ownedBodies[requestedId] == body then ownedBodies[requestedId] = nil end
    local brain = rawget(_G, "BanditBrain")
    if type(brain) == "table" and functionExists(brain, "Remove") then
        invoke(brain, "Remove", body)
    end
    callIfPresent(body, "removeFromSquare")
    callIfPresent(body, "removeFromWorld")
    return true
end

return BanditsAdapter
