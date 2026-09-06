local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")
local BaseManager = require("GoblinSurvivor/BaseManager")

local SquadManager = {
    squads = {},
    maxMembers = 16,
    minimumBaseGuards = 1,
    loaded = false
}

local LegacyModules
local function legacyModules()
    if LegacyModules == nil then
        LegacyModules = {
            NPCRegistry = require("GoblinSurvivor/NPCRegistry"),
            NpcAdapter = require("GoblinSurvivor/NpcAdapter")
        }
    end
    return LegacyModules
end

local function persistentData()
    if type(ModData) ~= "table" or type(ModData.getOrCreate) ~= "function" then
        return nil
    end
    local ok, data = pcall(ModData.getOrCreate, "GoblinSurvivor")
    return ok and type(data) == "table" and data or nil
end

local function onlinePlayer(name)
    if type(name) ~= "string" or type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return nil end
    local count = type(players.size) == "function" and players:size() or #players
    for index = 0, count - 1 do
        local player = type(players.get) == "function" and players:get(index) or players[index + 1]
        if player ~= nil and type(player.getUsername) == "function" then
            local okName, value = pcall(function() return player:getUsername() end)
            if okName and value == name then return player end
        end
    end
    return nil
end

local function uniqueMembers(members)
    if type(members) ~= "table" or #members < 1 or #members > SquadManager.maxMembers then return nil end
    local legacy = legacyModules()
    local result, seen = {}, {}
    for _, member in ipairs(members) do
        if not Net.safeId(member, 96) or seen[member] then return nil end
        local entry = legacy.NPCRegistry.get(member)
        if entry == nil or entry.active ~= true or entry.alive ~= true then
            return nil
        end
        seen[member] = true
        table.insert(result, member)
    end
    return result
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

local function applySquadTasks(squad)
    local legacy = legacyModules()
    local leaderObject = nil
    local leaderIsPlayer = squad.leader_player ~= nil
    if leaderIsPlayer then
        leaderObject = onlinePlayer(squad.leader_player)
    else
        leaderObject = legacy.NPCRegistry.body(squad.leader)
    end
    local leaderPoint = position(leaderObject)
    if leaderPoint == nil then
        return false, "squad leader is not currently available"
    end

    local applied = 0
    for index, member in ipairs(squad.members) do
        local body = legacy.NPCRegistry.body(member)
        if body ~= nil then
            local targetPlayer = nil
            local targetNpc = nil
            local mode = "FOLLOW"
            local target = leaderPoint
            if leaderIsPlayer then
                if member == Config.npcId then
                    targetPlayer = squad.leader_player
                else
                    targetNpc = Config.npcId
                    mode = "FOLLOW_GOBLIN"
                end
            elseif member ~= squad.leader then
                targetNpc = squad.leader
                mode = "FOLLOW_GOBLIN"
            else
                -- An NPC leader keeps its existing native task.
                applied = applied + 1
            end
            if targetNpc ~= nil then
                local targetBody = legacy.NPCRegistry.body(targetNpc)
                target = position(targetBody) or target
            end
            if member ~= squad.leader or leaderIsPlayer then
                local task = {
                    action = "GoTo",
                    mode = mode,
                    x = target.x,
                    y = target.y,
                    z = target.z,
                    target_player = targetPlayer,
                    target_npc_id = targetNpc,
                    follow_distance = 2 + ((index - 1) % 3)
                }
                local ok = legacy.NpcAdapter.setTasks(body, { task }, member)
                if ok then applied = applied + 1 end
            end
        end
    end
    if applied < 1 then return false, "no squad member accepted a follow task" end
    return true, "squad follow tasks accepted by native bodies"
end

local function returnSquadToBase(squad)
    local legacy = legacyModules()
    local point = BaseManager.point()
    for _, member in ipairs(squad.members) do
        local body = legacy.NPCRegistry.body(member)
        if body ~= nil then
            if point ~= nil then
                legacy.NpcAdapter.setTasks(body, {
                    {
                        action = "GoTo",
                        mode = "RETURN_TO_BASE",
                        x = point.x,
                        y = point.y,
                        z = point.z,
                        follow_distance = 2
                    }
                }, member)
            else
                legacy.NpcAdapter.clearTasks(body, member)
            end
        end
    end
end

local function save()
    local data = persistentData()
    if data == nil then return false end
    data.squads = {}
    for squadId, squad in pairs(SquadManager.squads) do
        data.squads[squadId] = {
            squad_id = squad.squad_id,
            leader = squad.leader,
            leader_player = squad.leader_player,
            goblin_member = squad.goblin_member,
            members = squad.members,
            formation = squad.formation,
            mission = squad.mission,
            combat_policy = squad.combat_policy,
            loot_policy = squad.loot_policy,
            home_base = squad.home_base,
            created_at = squad.created_at
        }
    end
    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, "GoblinSurvivor")
    end
    return true
end

function SquadManager.load()
    if SquadManager.loaded then return end
    if Config.bodyMode == "client_survivor" then
        -- Client-survivor squad state is owned by ClientSurvivorServer. Do not
        -- load the legacy registry just to validate an unused old save.
        SquadManager.loaded = true
        return
    end
    SquadManager.minimumBaseGuards = Config.minimumBaseGuards or 1
    local data = persistentData()
    local saved = data and data.squads or nil
    if type(saved) == "table" then
        for squadId, record in pairs(saved) do
            if type(record) == "table"
                and Net.safeId(squadId, 96)
                and Net.safeId(record.leader, 96)
                and record.formation ~= nil then
                local members = uniqueMembers(record.members)
                local formation = record.formation
                if members ~= nil and (formation == "line" or formation == "wedge"
                    or formation == "column" or formation == "ring" or formation == "loose") then
                    SquadManager.squads[squadId] = {
                        squad_id = squadId,
                        leader = record.leader,
                        leader_player = record.leader_player,
                        goblin_member = record.goblin_member,
                        members = members,
                        formation = formation,
                        mission = type(record.mission) == "string" and string.sub(record.mission, 1, 96) or "general expedition",
                        combat_policy = type(record.combat_policy) == "string" and string.sub(record.combat_policy, 1, 32) or "defensive",
                        loot_policy = type(record.loot_policy) == "string" and string.sub(record.loot_policy, 1, 32) or "useful",
                        home_base = type(record.home_base) == "string" and string.sub(record.home_base, 1, 96) or "base.primary",
                        created_at = type(record.created_at) == "number" and record.created_at or 0
                    }
                end
            end
        end
    end
    SquadManager.loaded = true
end

function SquadManager.form(args, goblinBody)
    SquadManager.load()
    if type(args) ~= "table" or not Net.safeId(args.squad_id or "squad.primary", 96)
        or not Net.safeId(args.leader, 96) then return false, "invalid squad identity" end
    local squadId = args.squad_id or "squad.primary"
    local leader = args.leader
    local legacy = legacyModules()
    local leaderNpc = legacy.NPCRegistry.get(leader)
    local leaderPlayer = onlinePlayer(leader)
    if leaderNpc == nil and leaderPlayer == nil then
        return false, "squad leader is not an online player or managed NPC"
    end
    local members = uniqueMembers(args.members)
    if members == nil then return false, "invalid squad members" end
    if leaderPlayer ~= nil then
        local goblin = legacy.NPCRegistry.get(Config.npcId)
        if goblin == nil or goblin.active ~= true or goblin.alive ~= true
            or goblinBody == nil or not legacy.NpcAdapter.isOwned(goblinBody, Config.npcId) then
            return false, "Goblin is unavailable for the expedition"
        end
        local foundGoblin = false
        for _, member in ipairs(members) do
            if member == Config.npcId then foundGoblin = true break end
        end
        if not foundGoblin then return false, "human-led squads must include Goblin" end
    end
    local formation = args.formation or "loose"
    if formation ~= "line" and formation ~= "wedge" and formation ~= "column"
        and formation ~= "ring" and formation ~= "loose" then return false, "invalid formation" end
    SquadManager.squads[squadId] = {
        squad_id = squadId,
        leader = leader,
        leader_player = leaderPlayer ~= nil and leader or nil,
        goblin_member = Config.npcId,
        members = members,
        formation = formation,
        mission = type(args.mission) == "string" and string.sub(args.mission, 1, 96) or "general expedition",
        combat_policy = "defensive",
        loot_policy = "useful",
        home_base = "base.primary",
        created_at = os.time()
    }
    local squad = SquadManager.squads[squadId]
    for _, member in ipairs(squad.members) do
        local entry = legacy.NPCRegistry.get(member)
        if entry ~= nil then entry.squad_id = squadId end
    end
    if not save() then
        SquadManager.squads[squadId] = nil
        return false, "squad could not be persisted"
    end
    local applied, detail = applySquadTasks(squad)
    if not applied then
        return true, "squad formed; follow task will be retried when members are available"
    end
    return true, detail
end

function SquadManager.dismiss(args)
    SquadManager.load()
    local squadId = type(args) == "table" and args.squad_id or nil
    if not Net.safeId(squadId or "", 96) then return false, "invalid squad id" end
    local squad = SquadManager.squads[squadId]
    if squad == nil then return false, "squad is unknown" end
    SquadManager.squads[squadId] = nil
    local legacy = legacyModules()
    for _, member in ipairs(squad.members) do
        local entry = legacy.NPCRegistry.get(member)
        if entry ~= nil and entry.squad_id == squadId then entry.squad_id = nil end
        local body = legacy.NPCRegistry.body(member)
        if body ~= nil then legacy.NpcAdapter.clearTasks(body, member) end
    end
    save()
    return true, "squad dismissed"
end

-- Re-apply persisted squad relationships without waiting for another Qwen
-- decision. The native engine owns body movement; this manager only refreshes
-- the high-level target and returns a squad to base if its human leader leaves.
function SquadManager.tick()
    SquadManager.load()
    if Config.bodyMode == "client_survivor" then return end
    local now = os.time() * 1000
    for _, squad in pairs(SquadManager.squads) do
        if squad.lastAppliedAt == nil or now - squad.lastAppliedAt >= 5000 then
            if squad.leader_player ~= nil and onlinePlayer(squad.leader_player) == nil then
                returnSquadToBase(squad)
            else
                applySquadTasks(squad)
            end
            squad.lastAppliedAt = now
        end
    end
end

function SquadManager.snapshot()
    SquadManager.load()
    return SquadManager.squads
end

return SquadManager
