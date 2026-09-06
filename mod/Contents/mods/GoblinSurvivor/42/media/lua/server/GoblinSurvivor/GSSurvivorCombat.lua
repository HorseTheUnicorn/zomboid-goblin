-- Bounded survivor combat facade.
--
-- This module owns target selection policy at the survivor layer while the
-- native adapter owns the physical IsoZombie target/path contract. Keeping
-- that boundary explicit makes combat replaceable without leaking engine
-- objects into the bridge or external brain.
local Identity = require("GoblinSurvivor/Identity")
local Perception = require("GoblinSurvivor/GSSurvivorPerception")

local Combat = {}

local function live(entity)
    if entity == nil or Perception.position(entity) == nil then return false end
    if type(entity.isExistInTheWorld) == "function" then
        local ok, exists = pcall(function() return entity:isExistInTheWorld() end)
        if ok and not exists then return false end
    end
    if type(entity.isDead) == "function" then
        local ok, dead = pcall(function() return entity:isDead() end)
        if ok and dead then return false end
    end
    return true
end

function Combat.findNearestThreat(entity, radius)
    if not Identity.isManaged(entity) then return nil, "survivor is not managed" end
    local threat = Perception.nearestThreat(entity, tonumber(radius) or 32)
    if threat == nil then return nil, "no nearby threat" end
    return threat, "nearby hostile zombie selected"
end

function Combat.attack(entity, target, adapter, survivorId)
    if not Identity.isManaged(entity) then
        return false, "survivor is not managed"
    end
    if not live(target) then return false, "combat target is unavailable" end
    if type(adapter) ~= "table" or type(adapter.setCombatTarget) ~= "function" then
        return false, "survivor combat adapter is unavailable"
    end
    local ok, detail = adapter.setCombatTarget(entity, target, survivorId)
    return ok == true, detail or (ok and "combat target accepted" or "combat target rejected")
end

function Combat.stop(entity, adapter, survivorId)
    if not Identity.isManaged(entity) then return false, "survivor is not managed" end
    if type(adapter) ~= "table" or type(adapter.clearTasks) ~= "function" then
        return false, "survivor combat adapter is unavailable"
    end
    return adapter.clearTasks(entity, survivorId)
end

function Combat.snapshot(entity)
    local data = Identity.data(entity)
    if data == nil then return nil end
    return {
        active = data.goblin_combat == true,
        target_active = data.goblin_combat == true,
        last_target_probe_at = tonumber(data.gss_target_probe_at) or 0
    }
end

return Combat
