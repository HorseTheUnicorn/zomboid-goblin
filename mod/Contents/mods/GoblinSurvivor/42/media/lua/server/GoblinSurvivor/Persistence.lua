local NPCRegistry = require("GoblinSurvivor/NPCRegistry")
local BaseManager = require("GoblinSurvivor/BaseManager")
local JobManager = require("GoblinSurvivor/JobManager")
local GuardManager = require("GoblinSurvivor/GuardManager")

local Persistence = {}

function Persistence.load()
    NPCRegistry.load()
    BaseManager.load()
    JobManager.load()
    GuardManager.load()
end

function Persistence.save()
    return NPCRegistry.save()
end

return Persistence
