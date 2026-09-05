-- Public standalone survivor engine facade.
-- Higher layers talk to SurvivorEntity semantics; only the native adapter
-- knows that the physical body is an IsoZombie.
local Profiles = require("GoblinSurvivor/Profiles")
local Identity = require("GoblinSurvivor/Identity")
local Visuals = require("GoblinSurvivor/GSSurvivorVisuals")
local Brain = require("GoblinSurvivor/GSSurvivorBrain")
local Combat = require("GoblinSurvivor/GSSurvivorCombat")
local Perception = require("GoblinSurvivor/GSSurvivorPerception")
local Registry = require("GoblinSurvivor/GSSurvivorRegistry")
local Sync = require("GoblinSurvivor/GSSurvivorSync")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")

local Survivor = { started = false, updateCount = 0 }

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function profileFor(entity, profile)
    if profile ~= nil then return profile end
    return Profiles.forId(Identity.getId(entity) or "dev.test.001")
end

function Survivor.Survivorize(entity, profile)
    profile = profileFor(entity, profile)
    if entity == nil or type(profile) ~= "table" then
        return false, "survivor donor and profile are required"
    end
    local generation = Identity.bodyGeneration(entity) or 1
    local ok, detail = Identity.mark(entity, profile, generation)
    if not ok then return false, detail end
    if not NpcAdapter.applySurvivorInvariants(entity, profile, false) then
        return false, "native survivor invariants could not be applied"
    end
    local visualOk, visualDetail = Visuals.apply(entity, profile, "survivorize")
    if not visualOk then return false, visualDetail end
    local brain = Brain.ensure(entity, profile)
    if brain == nil then return false, "survivor brain could not be created" end
    local data = Identity.data(entity)
    data.gss_ready = true
    data.gss_engine_version = 1
    data.gss_identity_dirty = false
    if type(entity.transmitModData) == "function" then pcall(entity.transmitModData, entity) end
    return true, "standalone survivor donor converted"
end

function Survivor.IsManaged(entity)
    return Identity.isManaged(entity)
end

function Survivor.GetID(entity)
    return Identity.getId(entity)
end

function Survivor.EnsureInvariants(entity, profile)
    if not Identity.isManaged(entity) then return false, "body is not a managed survivor" end
    profile = profileFor(entity, profile)
    if not NpcAdapter.applySurvivorInvariants(entity, profile, true) then
        return false, "native invariant check failed"
    end
    if not Visuals.ensure(entity, profile) then
        local data = Identity.data(entity)
        if data ~= nil then data.gss_visual_dirty = true end
        return false, "survivor visual state is unavailable"
    end
    if Brain.ensure(entity, profile) == nil then return false, "survivor brain is unavailable" end
    return true
end

function Survivor.Update(entity, profile, timestamp)
    if not Identity.isManaged(entity) then return false end
    timestamp = timestamp or nowMs()
    local data = Identity.data(entity)
    if data == nil then return false end
    Survivor.EnsureInvariants(entity, profile)
    local nextAt = tonumber(data.gss_next_update_at) or 0
    if timestamp < nextAt then return true end
    data.gss_next_update_at = timestamp + 250
    Perception.refresh(timestamp)
    local resolvedProfile = profileFor(entity, profile)
    local ok = Brain.update(entity, resolvedProfile, NpcAdapter, Perception, timestamp)
    NpcAdapter.tick(entity, resolvedProfile.id)
    Sync.publish(entity, Brain.get(entity), NpcAdapter.status(entity, resolvedProfile.id))
    Survivor.updateCount = Survivor.updateCount + 1
    return ok == true
end

function Survivor.UpdateAll(timestamp)
    Perception.refresh(timestamp or nowMs())
    Registry.each(function(entity, profile)
        Survivor.Update(entity, profile, timestamp)
    end)
end

function Survivor.setGoal(id, goal, leader)
    local entity = Registry.body(id)
    if entity == nil then return false, "survivor is not present" end
    return Brain.setGoal(entity, Registry.profile(id), goal, leader)
end

function Survivor.snapshot(entity)
    if not Identity.isManaged(entity) then return nil end
    local id = Identity.getId(entity)
    local profile = profileFor(entity)
    local brain = Brain.snapshot(entity)
    local data = Identity.data(entity)
    return {
        survivor_id = id,
        survivor_type = Identity.profileType(entity),
        body_generation = Identity.bodyGeneration(entity),
        display_name = profile.displayName,
        role = profile.role,
        goal = brain and brain.goal or "IDLE",
        task = brain and brain.task or nil,
        leader = brain and brain.leader or nil,
        external_brain = brain and brain.external_brain or "NONE",
        combat = Combat.snapshot(entity),
        visual_state = data and data.gss_visual_fingerprint or nil,
        protected = profile.immortal == true,
        update_count = Survivor.updateCount
    }
end

function Survivor.Start()
    if Survivor.started then return true end
    Sync.start()
    Survivor.started = true
    return true
end

function Survivor.OnDeath(entity)
    if not Identity.isManaged(entity) then return false end
    local data = Identity.data(entity)
    if data ~= nil then data.gss_body_lost_at = nowMs() end
    return true
end

return Survivor
