local IPC = require("GoblinSurvivor/IPC")
local Config = require("GoblinSurvivor/Config")

local EventLog = {}

function EventLog.emit(kind, fields)
    if type(kind) ~= "string" or #kind == 0 or #kind > 64 or type(fields) ~= "table" then return false end
    local requestId = "event-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 2147483647))
    local message = {
        protocol = Config.protocol, request_id = requestId,
        timestamp_ms = os.time() * 1000, type = "event." .. kind
    }
    for key, value in pairs(fields) do message[key] = value end
    return IPC.publish("events", message, requestId)
end

return EventLog
