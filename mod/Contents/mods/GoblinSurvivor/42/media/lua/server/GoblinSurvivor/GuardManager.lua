local Config = require("GoblinSurvivor/Config")
local BaseManager = require("GoblinSurvivor/BaseManager")
local NPCRegistry = require("GoblinSurvivor/NPCRegistry")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")

local GuardManager = {
    assignments = {},
    state = "IDLE",
    lastDetail = "",
    loaded = false
}

local function safeId(value)
    return type(value) == "string" and #value > 0 and #value <= 96
        and string.find(value, "^[A-Za-z0-9_%.:%-]+$") ~= nil
end

local function setDetail(state, detail)
    GuardManager.state = state
    GuardManager.lastDetail = detail or ""
end

local function persistentData()
    if type(ModData) ~= "table" or type(ModData.getOrCreate) ~= "function" then
        return nil
    end
    local ok, data = pcall(ModData.getOrCreate, "GoblinSurvivor")
    return ok and type(data) == "table" and data or nil
end

local function save()
    local data = persistentData()
    if data == nil then return false end
    data.guards = {}
    for npcId, assigned in pairs(GuardManager.assignments) do
        if assigned == true then data.guards[npcId] = true end
    end
    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, "GoblinSurvivor")
    end
    return true
end

function GuardManager.load()
    if GuardManager.loaded then return end
    local data = persistentData()
    local saved = data and data.guards or nil
    if type(saved) == "table" then
        for npcId, assigned in pairs(saved) do
            if assigned == true and safeId(npcId) then
                GuardManager.assignments[npcId] = true
                local entry = NPCRegistry.get(npcId)
                if entry ~= nil then entry.role = "guard" end
            end
        end
    end
    GuardManager.loaded = true
end

function GuardManager.assign(npcId)
    GuardManager.load()
    if not safeId(npcId) then
        return false, "invalid guard NPC id"
    end
    if not BaseManager.hasAnchor() then
        return false, "home base has not been set"
    end
    local entry = NPCRegistry.get(npcId)
    if entry == nil or entry.active ~= true or entry.alive ~= true then
        return false, "guard NPC is unavailable"
    end
    local base = BaseManager.snapshot()
    local guardCount = math.max(
        base.assigned_guards or 0,
        base.minimum_guards or 1
    )
    if not BaseManager.setAssignedGuards(guardCount) then
        return false, "guard assignment could not be persisted"
    end
    GuardManager.assignments[npcId] = true
    entry.role = "guard"
    if not save() then
        GuardManager.assignments[npcId] = nil
        return false, "guard assignment could not be persisted"
    end
    setDetail("IDLE", "guard assignment recorded")
    return true, "guard assignment recorded"
end

-- MVP base security: keep Goblin at the persisted base anchor using the
-- native movement task path used by FOLLOW/RETURN_TO_BASE. More specific
-- posts and patrol routes can be layered on without changing the body
-- adapter boundary.
function GuardManager.secure(args, zombie)
    GuardManager.load()
    if type(args) ~= "table" or args.npc_id ~= Config.npcId then
        return false, "unknown guard NPC"
    end
    if zombie == nil or not NpcAdapter.isOwned(zombie) then
        return false, "Goblin NPC is not a verified friendly native body"
    end
    local assigned, detail = GuardManager.assign(Config.npcId)
    if not assigned then return false, detail end
    local point = BaseManager.point()
    if point == nil then
        return false, "home base has not been set"
    end
    local ok, taskDetail = NpcAdapter.setTasks(zombie, {
        {
            action = "GoTo",
            mode = "GUARD",
            x = point.x,
            y = point.y,
            z = point.z
        }
    })
    if not ok then
        setDetail("RETURN", taskDetail)
        return false, taskDetail
    end
    setDetail("PATROL", "Goblin is returning to the persisted base guard area")
    return true, "base security task accepted"
end

function GuardManager.snapshot()
    GuardManager.load()
    local base = BaseManager.snapshot()
    base.defense_state = GuardManager.state
    base.defense_detail = GuardManager.lastDetail
    base.guards = {}
    for npcId, assigned in pairs(GuardManager.assignments) do
        if assigned == true then table.insert(base.guards, npcId) end
    end
    table.sort(base.guards)
    return base
end

return GuardManager
