-- Stable logical identity for a GoblinSurvivor survivor entity.
--
-- The physical B42 body is an IsoZombie, but this module is the only place
-- higher layers need to know how a managed body is identified.  ModData is
-- authoritative and survives the temporary lifetime of a physical donor.
local Identity = {
    version = 1,
    marker = "GoblinSurvivorNPC"
}

local function validId(value)
    return type(value) == "string" and #value >= 1 and #value <= 96
        and string.find(value, "^[A-Za-z0-9_%.:%-]+$") ~= nil
end

function Identity.data(entity)
    if entity == nil or type(entity.getModData) ~= "function" then return nil end
    local ok, data = pcall(function() return entity:getModData() end)
    return ok and type(data) == "table" and data or nil
end

function Identity.getId(entity)
    local data = Identity.data(entity)
    if data == nil then return nil end
    local value = data.GoblinSurvivorID or data.goblin_npc_id
    return validId(value) and value or nil
end

function Identity.isManaged(entity)
    local data = Identity.data(entity)
    return data ~= nil
        and data.GoblinSurvivorNPC == true
        and validId(data.GoblinSurvivorID)
        and tonumber(data.GoblinSurvivorVersion) ~= nil
        and data.goblin_engine == "native"
        and data.goblin_owned == true
end

function Identity.profileType(entity)
    local data = Identity.data(entity)
    if data == nil then return nil end
    return data.GoblinSurvivorType or data.goblin_survivor_type
end

function Identity.bodyGeneration(entity)
    local data = Identity.data(entity)
    return data ~= nil and tonumber(data.GoblinSurvivorBodyGeneration) or nil
end

local function set(data, key, value)
    if data[key] == value then return false end
    data[key] = value
    return true
end

function Identity.mark(entity, profile, generation)
    if entity == nil or type(profile) ~= "table" then
        return false, "survivor profile is required"
    end
    local id = profile.id or profile.survivorId
    if not validId(id) then return false, "survivor profile has an invalid id" end
    local data = Identity.data(entity)
    if data == nil then return false, "survivor ModData is unavailable" end

    local changed = false
    local profileType = profile.type or "COMPANION"
    local displayName = profile.displayName or profile.name or id
    changed = set(data, "GoblinSurvivorNPC", true) or changed
    changed = set(data, "GoblinSurvivorID", id) or changed
    changed = set(data, "GoblinSurvivorType", profileType) or changed
    changed = set(data, "GoblinSurvivorVersion", Identity.version) or changed
    changed = set(data, "GoblinSurvivorBodyGeneration",
        tonumber(generation) or tonumber(data.GoblinSurvivorBodyGeneration) or 1) or changed

    -- Compatibility markers are kept for the existing bridge/roster code. They
    -- are mirrors of the identity above, not a second ownership mechanism.
    changed = set(data, "goblin_engine", "native") or changed
    changed = set(data, "goblin_npc_id", id) or changed
    changed = set(data, "goblin_owned", true) or changed
    changed = set(data, "goblin_friendly", true) or changed
    changed = set(data, "goblin_hostile", false) or changed
    changed = set(data, "goblin_friendly_survivor", true) or changed
    changed = set(data, "goblin_body_class", "IsoZombie") or changed
    changed = set(data, "goblin_survivor_type", profileType) or changed
    changed = set(data, "goblin_display_name", displayName) or changed
    changed = set(data, "goblin_protected", profile.immortal == true) or changed
    changed = set(data, "goblin_infection_immune", profile.infectionImmune == true) or changed
    changed = set(data, "goblin_requires_food", profile.needsFood == true) or changed
    changed = set(data, "goblin_requires_water", profile.needsWater == true) or changed
    changed = set(data, "goblin_requires_sleep", profile.needsSleep == true) or changed
    if data.gss_identity_dirty == nil then
        data.gss_identity_dirty = false
        changed = true
    end
    if changed and type(entity.transmitModData) == "function" then
        pcall(entity.transmitModData, entity)
    end
    return true, data, changed
end

function Identity.ensure(entity, profile)
    if Identity.isManaged(entity) then return true, Identity.data(entity) end
    return Identity.mark(entity, profile)
end

return Identity
