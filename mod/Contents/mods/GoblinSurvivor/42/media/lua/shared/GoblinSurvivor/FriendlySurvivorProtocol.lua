-- Shared, bounded wire contract for the native friendly-survivor controller.
-- The server remains authoritative for the IsoZombie body and movement. This
-- table is only the small state envelope sent through the PZ command packet.
local Protocol = {
    module = "GoblinSurvivor",
    stateCommand = "friendly_survivor_state",
    requestCommand = "friendly_survivor_state_request",
    version = 1,
    maxEntityId = 96,
    maxUsername = 96,
    maxMode = 32
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

function Protocol.position(entity)
    if entity == nil
        or type(entity.getX) ~= "function"
        or type(entity.getY) ~= "function"
        or type(entity.getZ) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return entity:getX(), entity:getY(), entity:getZ()
    end)
    if not ok or not finiteNumber(x) or not finiteNumber(y)
        or not finiteNumber(z) then
        return nil
    end
    return { x = x, y = y, z = z }
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

function Protocol.validSnapshot(value)
    if type(value) ~= "table"
        or value.protocol ~= Protocol.version
        or not Protocol.safeText(value.entity_id, Protocol.maxEntityId, false)
        or value.entity_class ~= "IsoZombie"
        or type(value.sequence) ~= "number"
        or math.floor(value.sequence) ~= value.sequence
        or value.sequence < 1
        or not finiteNumber(value.x)
        or not finiteNumber(value.y)
        or not finiteNumber(value.z)
        or not Protocol.safeText(value.mode, Protocol.maxMode, false)
        or not finiteNumber(value.server_timestamp_ms) then
        return false
    end
    if value.target_username ~= nil
        and not Protocol.safeText(value.target_username, Protocol.maxUsername, false) then
        return false
    end
    if value.distance_tiles ~= nil
        and (not finiteNumber(value.distance_tiles) or value.distance_tiles < 0) then
        return false
    end
    return true
end

return Protocol
