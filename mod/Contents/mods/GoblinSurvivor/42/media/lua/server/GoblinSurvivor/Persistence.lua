local NPCRegistry = require("GoblinSurvivor/NPCRegistry")
local BaseManager = require("GoblinSurvivor/BaseManager")

local Persistence = {}

function Persistence.load()
    NPCRegistry.load()
    BaseManager.load()
end

function Persistence.save()
    return NPCRegistry.save()
end

return Persistence
