local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")
local NPCRegistry = require("GoblinSurvivor/NPCRegistry")

local JobManager = { assignments = {}, loaded = false }
local allowed = {
    wander = true, guard = true, patrol = true, scout = true, haul = true,
    build = true, farm = true, loot = true, medic = true, quartermaster = true
}

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
    data.jobs = {}
    for npcId, job in pairs(JobManager.assignments) do
        data.jobs[npcId] = job
    end
    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, "GoblinSurvivor")
    end
    return true
end

function JobManager.load()
    if JobManager.loaded then return end
    local data = persistentData()
    local saved = data and data.jobs or nil
    if type(saved) == "table" then
        for npcId, job in pairs(saved) do
            if Net.safeId(npcId, 96) and type(job) == "string"
                and allowed[string.lower(job)] then
                local normalized = string.lower(job)
                JobManager.assignments[npcId] = normalized
                local entry = NPCRegistry.get(npcId)
                if entry ~= nil then entry.role = normalized end
            end
        end
    end
    JobManager.loaded = true
end

function JobManager.assign(args)
    JobManager.load()
    if type(args) ~= "table" or args.npc_id ~= Config.npcId
        or not Net.safeText(args.job, 32, false) or not allowed[string.lower(args.job)] then
        return false, "unsupported NPC job"
    end
    local entry = NPCRegistry.get(Config.npcId)
    if entry == nil or entry.active ~= true or entry.alive ~= true then
        return false, "NPC is unavailable"
    end
    local job = string.lower(args.job)
    JobManager.assignments[Config.npcId] = job
    entry.role = job
    if not save() then return false, "job assignment could not be persisted" end
    return true, "job assigned and persisted"
end

function JobManager.snapshot()
    JobManager.load()
    local result = {}
    for npcId, job in pairs(JobManager.assignments) do result[npcId] = job end
    return result
end

return JobManager
