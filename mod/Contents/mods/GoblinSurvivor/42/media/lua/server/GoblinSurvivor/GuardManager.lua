local BaseManager = require("GoblinSurvivor/BaseManager")

local GuardManager = {}

function GuardManager.assign(npcId)
    if type(npcId) ~= "string" or not BaseManager.canDepart(0) then return false end
    return true
end

function GuardManager.snapshot()
    return BaseManager.snapshot()
end

return GuardManager
