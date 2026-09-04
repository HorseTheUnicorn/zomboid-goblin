local Config = require("GoblinSurvivor/Config")
local Net = require("GoblinSurvivor/Net")

local JobManager = { assignments = {} }
local allowed = {
    wander = true, guard = true, patrol = true, scout = true, haul = true,
    build = true, farm = true, loot = true, medic = true, quartermaster = true
}

function JobManager.assign(args)
    if type(args) ~= "table" or args.npc_id ~= Config.npcId
        or not Net.safeText(args.job, 32, false) or not allowed[string.lower(args.job)] then
        return false, "unsupported NPC job"
    end
    JobManager.assignments[Config.npcId] = string.lower(args.job)
    return true, "job assigned"
end

function JobManager.snapshot()
    return JobManager.assignments
end

return JobManager
