local Config = require("GoblinSurvivor/Config")
local BanditsAdapter = require("GoblinSurvivor/BanditsAdapter")

local Protection = {}

local function callIfPresent(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then
        return false
    end
    local ok = pcall(object[method], object, ...)
    return ok
end

function Protection.apply(zombie)
    if zombie == nil or not Config.protected then return false end
    local data = nil
    if type(zombie.getModData) == "function" then
        local ok, result = pcall(function() return zombie:getModData() end)
        if ok and type(result) == "table" then data = result end
    end
    if data ~= nil then
        data.goblin_npc_id = Config.npcId
        data.goblin_protected = true
        data.goblin_infection_immune = true
        data.goblin_needs_disabled = true
    end
    -- Use engine methods only when this Build 42 runtime exposes them.  The
    -- recovery loop remains the authoritative fallback for missing hooks.
    callIfPresent(zombie, "setImmortal", true)
    callIfPresent(zombie, "setHealth", 1.0)
    local brain = BanditsAdapter.getBrain(zombie)
    if brain ~= nil then
        brain.infection = 0
        brain.hunger = 0
        brain.thirst = 0
        brain.fatigue = 0
    end
    return true
end

function Protection.isProtected(zombie)
    if zombie == nil or type(zombie.getModData) ~= "function" then return false end
    local ok, data = pcall(function() return zombie:getModData() end)
    return ok and type(data) == "table" and data.goblin_protected == true
end

return Protection
