-- Wire contract for the client-rendered human survivor slice.
--
-- Project Zomboid's vanilla multiplayer stream has no IsoSurvivor packet
-- type. The server therefore owns this small authoritative snapshot and each
-- modded client renders its own IsoSurvivor from it.
local Protocol = {
    module = "GoblinSurvivor",
    stateCommand = "client_survivor_state",
    requestCommand = "client_survivor_state_request",
    speechCommand = "client_survivor_say",
    version = 1,
    entityClass = "IsoSurvivor",
    maxEntityId = 96,
    maxDisplayName = 48,
    maxMode = 32,
    maxSpeech = 240
}

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function Protocol.nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and finiteNumber(value) then return value end
    end
    return os.time() * 1000
end

function Protocol.safeText(value, maximum, allowEmpty)
    if type(value) ~= "string" or #value > maximum then return false end
    if not allowEmpty and #value == 0 then return false end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
            return false
        end
    end
    return true
end

local function validColor(value)
    return type(value) == "table"
        and finiteNumber(tonumber(value.r))
        and finiteNumber(tonumber(value.g))
        and finiteNumber(tonumber(value.b))
end

local function validItemType(value)
    return value == nil
        or (Protocol.safeText(value, 96, false)
            and string.match(value, "^Base%.[A-Za-z0-9_]+$") ~= nil)
end

local function validOutfit(value)
    if type(value) ~= "table" then return false end
    for _, key in ipairs({ "top", "outer", "pants", "shoes", "head", "back" }) do
        if not validItemType(value[key]) then return false end
    end
    return true
end

function Protocol.validSnapshot(value)
    if type(value) ~= "table"
        or value.protocol ~= Protocol.version
        or not Protocol.safeText(value.actor_id, Protocol.maxEntityId, false)
        or value.entity_class ~= Protocol.entityClass
        or not finiteNumber(value.sequence)
        or math.floor(value.sequence) ~= value.sequence
        or value.sequence < 1
        or not finiteNumber(value.x)
        or not finiteNumber(value.y)
        or not finiteNumber(value.z)
        or not Protocol.safeText(value.mode, Protocol.maxMode, false)
        or not finiteNumber(value.server_timestamp_ms)
        or not Protocol.safeText(value.display_name, Protocol.maxDisplayName, false) then
        return false
    end
    if type(value.profile) ~= "table" then return false end
    if value.body_generation ~= nil
        and (not finiteNumber(value.body_generation)
            or math.floor(value.body_generation) ~= value.body_generation
            or value.body_generation < 0) then
        return false
    end
    if value.health ~= nil and not finiteNumber(value.health) then return false end
    if value.alive ~= nil and type(value.alive) ~= "boolean" then return false end
    if value.body_present ~= nil and type(value.body_present) ~= "boolean" then return false end
    if value.god_mode ~= nil and type(value.god_mode) ~= "boolean" then return false end
    if value.friendly ~= nil and type(value.friendly) ~= "boolean" then return false end
    if value.hostile_to_zombies ~= nil and type(value.hostile_to_zombies) ~= "boolean" then return false end
    if value.work_status ~= nil
        and not Protocol.safeText(value.work_status, 64, false) then return false end
    if value.work_count ~= nil
        and (not finiteNumber(value.work_count) or value.work_count < 0
            or math.floor(value.work_count) ~= value.work_count) then return false end
    -- Every managed body carries the same non-empty rifle contract; the
    -- server and client live diagnostics verify the concrete item type.
    if value.firearm_type ~= nil
        and not Protocol.safeText(value.firearm_type, 64, true) then return false end
    if value.weapon_policy ~= nil
        and not Protocol.safeText(value.weapon_policy, 64, false) then return false end
    if value.profile.sex ~= nil
        and not Protocol.safeText(value.profile.sex, 16, false) then return false end
    if value.profile.hair ~= nil
        and not Protocol.safeText(value.profile.hair, 32, false) then return false end
    if value.profile.beard ~= nil
        and not Protocol.safeText(value.profile.beard, 32, false) then return false end
    if value.profile.skinTone ~= nil
        and not Protocol.safeText(value.profile.skinTone, 32, false) then return false end
    if value.profile.hairColor ~= nil and not validColor(value.profile.hairColor) then
        return false
    end
    if value.profile.outfit ~= nil and not validOutfit(value.profile.outfit) then
        return false
    end
    return true
end

function Protocol.validSpeech(value)
    return type(value) == "table"
        and value.protocol == Protocol.version
        and Protocol.safeText(value.actor_id, Protocol.maxEntityId, false)
        and finiteNumber(value.speech_sequence)
        and math.floor(value.speech_sequence) == value.speech_sequence
        and value.speech_sequence >= 1
        and Protocol.safeText(value.text, Protocol.maxSpeech, false)
end

return Protocol
