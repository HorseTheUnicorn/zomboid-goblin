local IPC = require("GoblinSurvivor/IPC")
local Config = require("GoblinSurvivor/Config")
local Protocol = require("GoblinSurvivor/ClientSurvivorProtocol")

local EventLog = { sequence = 0 }

function EventLog.emit(kind, fields)
    if type(kind) ~= "string" or #kind == 0 or #kind > 64 or type(fields) ~= "table" then return false end
    -- B42's Lua math library does not expose math.random. Event identifiers
    -- need uniqueness, not randomness; retain millisecond time and a counter.
    EventLog.sequence = EventLog.sequence + 1
    local now = Protocol.nowMs()
    local requestId = "event-" .. tostring(now) .. "-" .. tostring(EventLog.sequence)
    local message = {
        protocol = Config.protocol, request_id = requestId,
        timestamp_ms = now, type = "event." .. kind
    }
    for key, value in pairs(fields) do message[key] = value end
    return IPC.publish("events", message, requestId)
end

return EventLog
