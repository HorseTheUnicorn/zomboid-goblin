local IPC = require("GoblinSurvivor/IPC")
local Config = require("GoblinSurvivor/Config")

local EventLog = { sequence = 0 }

local function nowMs()
    local timestampMs = rawget(_G, "getTimestampMs")
    if type(timestampMs) == "function" then
        local ok, value = pcall(timestampMs)
        if ok and type(value) == "number" and value > 0 then
            return value
        end
    end
    local timestamp = rawget(_G, "getTimestamp")
    if type(timestamp) == "function" then
        local ok, value = pcall(timestamp)
        if ok and type(value) == "number" and value > 0 then
            return value * 1000
        end
    end
    if type(os) == "table" and type(os.time) == "function" then
        return os.time() * 1000
    end
    return 1
end

local function eventStem(now)
    EventLog.sequence = EventLog.sequence + 1
    local uuidFn = rawget(_G, "getRandomUUID")
    if type(uuidFn) == "function" then
        local ok, value = pcall(uuidFn)
        if ok and type(value) == "string" and #value > 0 then
            return "event-" .. value
        end
    end
    return "event-" .. tostring(now) .. "-" .. tostring(EventLog.sequence)
end

function EventLog.emit(kind, fields)
    if type(kind) ~= "string" or #kind == 0 or #kind > 64 or type(fields) ~= "table" then return false end
    local timestamp = nowMs()
    local requestId = eventStem(timestamp)
    local message = {
        protocol = Config.protocol,
        request_id = requestId,
        timestamp_ms = timestamp,
        type = "event." .. kind
    }
    for key, value in pairs(fields) do message[key] = value end
    return IPC.publish("events", message, requestId)
end

return EventLog
