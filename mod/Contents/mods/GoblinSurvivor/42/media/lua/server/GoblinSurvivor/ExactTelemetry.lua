local Telemetry = require("GoblinSurvivor/Telemetry")

local ExactTelemetry = {}

function ExactTelemetry.write()
    return Telemetry.writeExactState()
end

return ExactTelemetry
