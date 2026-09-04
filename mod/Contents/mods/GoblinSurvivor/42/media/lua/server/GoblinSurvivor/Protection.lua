local Config = require("GoblinSurvivor/Config")

local Protection = {}

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

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
        data.goblin_requires_food = false
        data.goblin_requires_water = false
        data.goblin_requires_sleep = false
        data.goblin_last_protected_at = nowMs()
    end
    -- Use engine methods only when this Build 42 runtime exposes them.  The
    -- recovery loop remains the authoritative fallback for missing hooks.
    callIfPresent(zombie, "setImmortal", true)
    callIfPresent(zombie, "setImmortalTutorialZombie", true)
    callIfPresent(zombie, "setNoDamage", true)
    callIfPresent(zombie, "setTarget", nil)
    callIfPresent(zombie, "setHealth", 1.0)
    return true
end

function Protection.isProtected(zombie)
    if zombie == nil or type(zombie.getModData) ~= "function" then return false end
    local ok, data = pcall(function() return zombie:getModData() end)
    return ok and type(data) == "table" and data.goblin_protected == true
end

return Protection
