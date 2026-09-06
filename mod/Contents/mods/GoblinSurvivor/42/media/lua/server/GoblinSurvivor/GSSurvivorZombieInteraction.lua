-- Bounded arbitration between vanilla zombies and managed survivors.
-- Never clear or replace a live player target: ordinary zombie-vs-player
-- behavior belongs to Project Zomboid and is outside this module's authority.
local Identity = require("GoblinSurvivor/Identity")
local Perception = require("GoblinSurvivor/GSSurvivorPerception")

local Interaction = {
    scanIntervalMs = 500,
    targetRadius = 24,
    lastRefreshAt = 0,
    considered = 0,
    assigned = 0
}

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function call(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then return false, nil end
    local ok, value = pcall(object[method], object, ...)
    return ok, value
end

local function live(entity)
    if entity == nil then return false end
    local point = Perception.position(entity)
    if point == nil then return false end
    local ok, dead = call(entity, "isDead")
    return not (ok and dead == true)
end

local function isPlayer(entity)
    local ok, value = call(entity, "isPlayer")
    return ok and value == true
end

local function currentTarget(zombie)
    local ok, value = call(zombie, "getTarget")
    return ok and value or nil
end

local function keepVanillaTarget(target)
    if not live(target) then return false end
    -- A current player target is always preserved. A current hostile zombie
    -- target is also left alone; this module only fills an empty target slot.
    return true
end

function Interaction.consider(zombie, timestamp)
    if zombie == nil or Identity.isManaged(zombie) or not live(zombie) then return false end
    timestamp = timestamp or nowMs()
    local data = Identity.data(zombie)
    if data ~= nil and timestamp - (tonumber(data.gss_target_probe_at) or 0)
        < Interaction.scanIntervalMs then return false end
    if data ~= nil then data.gss_target_probe_at = timestamp end
    Interaction.considered = Interaction.considered + 1

    local target = currentTarget(zombie)
    if keepVanillaTarget(target) then
        -- A valid player target is never stolen by the survivor arbitration.
        -- In particular, do not touch NoLungeAttack/NoLungeTarget or target
        -- state when the vanilla engine already selected an IsoPlayer.
        return false
    end
    local survivor = Perception.nearbySurvivors(zombie, Interaction.targetRadius)[1]
    if survivor == nil or not live(survivor) then return false end
    local assigned = call(zombie, "setTarget", survivor)
    if assigned then Interaction.assigned = Interaction.assigned + 1 end
    return assigned
end

function Interaction.update(timestamp)
    timestamp = timestamp or nowMs()
    if timestamp - Interaction.lastRefreshAt < Interaction.scanIntervalMs then return false end
    Interaction.lastRefreshAt = timestamp
    Perception.refresh(timestamp)
    -- The cache contains all local normal zombies, but only this one cheap
    -- arbitration pass is performed per interval. A live player target is
    -- never overwritten.
    for _, zombie in ipairs(Perception.allZombies()) do
        Interaction.consider(zombie, timestamp)
    end
    return true
end

function Interaction.onZombieUpdate(zombie)
    Perception.refresh(nowMs())
    return Interaction.consider(zombie, nowMs())
end

function Interaction.stats()
    return {
        considered = Interaction.considered,
        assigned = Interaction.assigned,
        scan_interval_ms = Interaction.scanIntervalMs,
        target_radius = Interaction.targetRadius
    }
end

return Interaction
