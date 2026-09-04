local NPCRegistry = require("GoblinSurvivor/NPCRegistry")

local Persistence = {}

function Persistence.load()
    NPCRegistry.load()
end

function Persistence.save()
    return NPCRegistry.save()
end

return Persistence
