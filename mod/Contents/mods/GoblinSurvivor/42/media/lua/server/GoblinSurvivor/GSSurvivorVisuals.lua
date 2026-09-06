-- Human visual application for a survivor donor.
-- All engine surfaces are capability-gated because B42 server/client builds
-- do not expose every visual helper on every body type.
local Identity = require("GoblinSurvivor/Identity")

local Visuals = {}

local function call(object, method, ...)
    if object == nil or type(object[method]) ~= "function" then return false end
    return pcall(object[method], object, ...)
end

local function setField(data, key, value)
    if data[key] == value then return false end
    data[key] = value
    return true
end

local function color(value)
    local constructor = rawget(_G, "ImmutableColor")
    if type(value) ~= "table" or constructor == nil
        or type(constructor.new) ~= "function" then return nil end
    local ok, result = pcall(constructor.new,
        tonumber(value.r) or 0, tonumber(value.g) or 0, tonumber(value.b) or 0)
    return ok and result or nil
end

function Visuals.fingerprint(profile)
    if type(profile) ~= "table" then return "none" end
    local hairColor = profile.hairColor or {}
    return table.concat({
        tostring(profile.sex or ""), tostring(profile.skinTextureName or ""),
        tostring(profile.hairModel or ""), tostring(profile.beardModel or ""),
        tostring(hairColor.r or ""), tostring(hairColor.g or ""),
        tostring(hairColor.b or ""), tostring(profile.displayName or "")
    }, "|")
end

function Visuals.apply(entity, profile, reason)
    if entity == nil or type(profile) ~= "table" then
        return false, "visual profile is unavailable"
    end
    local data = Identity.data(entity)
    if data == nil then return false, "survivor ModData is unavailable" end
    local human = nil
    if type(entity.getHumanVisual) == "function" then
        local ok, value = pcall(function() return entity:getHumanVisual() end)
        if ok then human = value end
    end
    -- IsoSurvivor is the dedicated-server-safe Build 42 body factory result.
    -- Unlike IsoZombie it does not implement IHumanVisual itself, but its
    -- SurvivorDesc owns the HumanVisual used to render the body.
    if human == nil and type(entity.getDescriptor) == "function" then
        local okDescriptor, descriptor = pcall(function()
            return entity:getDescriptor()
        end)
        if okDescriptor and descriptor ~= nil
            and type(descriptor.getHumanVisual) == "function" then
            local okVisual, value = pcall(function()
                return descriptor:getHumanVisual()
            end)
            if okVisual then human = value end
        end
    end
    if human == nil then return false, "human visual surface is unavailable" end

    -- Remove inherited zombie damage/noise cues without rebuilding clothing on
    -- every update. The donor's valid human descriptor remains authoritative.
    call(human, "removeDirt")
    call(human, "removeBlood")
    if profile.sex == "female" then call(entity, "setFemaleEtc", true) end
    if profile.sex == "male" then call(entity, "setFemaleEtc", false) end
    if profile.skinTextureName ~= nil then
        call(human, "setSkinTextureName", profile.skinTextureName)
    end
    if profile.hairModel ~= nil then call(human, "setHairModel", profile.hairModel) end
    if profile.beardModel ~= nil and profile.sex ~= "female" then
        call(human, "setBeardModel", profile.beardModel)
    end
    local hairColor = color(profile.hairColor)
    if hairColor ~= nil then
        call(human, "setHairColor", hairColor)
        if profile.sex ~= "female" then call(human, "setBeardColor", hairColor) end
    end
    if profile.displayName ~= nil then
        if not call(entity, "setDisplayName", profile.displayName) then
            call(entity, "setName", profile.displayName)
        end
    end
    call(entity, "setSkeleton", false)
    if profile.walkSpeed ~= nil then
        call(entity, "setVariable", "MovementSpeed", tonumber(profile.walkSpeed) or 0.70)
    end

    local fingerprint = Visuals.fingerprint(profile)
    setField(data, "gss_visual_fingerprint", fingerprint)
    setField(data, "gss_visual_dirty", false)
    setField(data, "gss_visual_last_reason", tostring(reason or "spawn"))
    setField(data, "gss_visual_applied_at", os.time() * 1000)
    if type(entity.transmitModData) == "function" then pcall(entity.transmitModData, entity) end
    return true, "survivor human visual profile applied"
end

function Visuals.ensure(entity, profile)
    local data = Identity.data(entity)
    if data == nil then return false end
    local fingerprint = Visuals.fingerprint(profile)
    if data.gss_visual_dirty == true or data.gss_visual_fingerprint ~= fingerprint then
        return Visuals.apply(entity, profile, "dirty-check")
    end
    return true
end

return Visuals
