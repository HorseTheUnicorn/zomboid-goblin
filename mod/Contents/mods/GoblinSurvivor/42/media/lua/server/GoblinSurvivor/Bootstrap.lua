local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Persistence = require("GoblinSurvivor/Persistence")
local GoblinNPC = require("GoblinSurvivor/GoblinNPC")
local Telemetry = require("GoblinSurvivor/Telemetry")
local CommandLoop = require("GoblinSurvivor/CommandLoop")

local Bootstrap = {
    started = false,
    lastHeartbeat = 0
}

local function monotonicSeconds()
    if type(getTimestampMs) == "function" then
        local ok, timestamp = pcall(getTimestampMs)
        if ok and type(timestamp) == "number" then
            return timestamp / 1000
        end
    end
    return os.time()
end

local function tick()
    if not Bootstrap.started then
        Bootstrap.start()
        return
    end
    local now = monotonicSeconds()
    -- Command consumption and protection are server-local and remain
    -- independent of the slower telemetry heartbeat.
    CommandLoop.tick()
    if Bootstrap.lastHeartbeat == 0 or now - Bootstrap.lastHeartbeat >= Config.heartbeatSeconds then
        Telemetry.writeHeartbeat()
        Telemetry.writeState()
        Bootstrap.lastHeartbeat = now
    end
end

local function emitInitialTelemetry()
    if not Bootstrap.started then
        Bootstrap.start()
    end
    if not Bootstrap.started then
        print("[GoblinSurvivor] server-ready telemetry skipped because bootstrap is not ready")
        return
    end
    Telemetry.writeHeartbeat()
    Telemetry.writeState()
    Telemetry.writeExactState()
    Bootstrap.lastHeartbeat = monotonicSeconds()
end

function Bootstrap.start()
    if Bootstrap.started then
        return
    end
    Config.refresh()
    if not IPC.initialize() then
        return
    end
    Persistence.load()
    Bootstrap.started = true
    -- Do not query multiplayer players during this callback.  On some Build
    -- 42 server startup paths OnServerStarted is emitted before the UDP
    -- engine is fully usable; the next OnTick performs the first telemetry
    -- pass after the engine is ready.
    Bootstrap.lastHeartbeat = monotonicSeconds()
end

if Events and Events.OnZombieDead and type(Events.OnZombieDead.Add) == "function" then
    Events.OnZombieDead.Add(function(zombie)
        GoblinNPC.onZombieDeath(zombie)
    end)
end

-- Build 42's getOnlinePlayers() is not safe during OnInitGlobalModData: the
-- server UDP engine is still nil at that point.  Start after the documented
-- server-ready event so telemetry and body discovery can use the MP API.
-- Initialization itself is safe during OnInitGlobalModData: it only loads
-- configuration, validates the bridge marker, and registers network hooks.
-- Player/UDP access is deferred to tick(), which runs after world startup.
if Events and Events.OnInitGlobalModData and type(Events.OnInitGlobalModData.Add) == "function" then
    Events.OnInitGlobalModData.Add(Bootstrap.start)
end
if Events and Events.OnServerStarted and type(Events.OnServerStarted.Add) == "function" then
    Events.OnServerStarted.Add(emitInitialTelemetry)
end
if Events and Events.OnTick and type(Events.OnTick.Add) == "function" then
    Events.OnTick.Add(tick)
end
if Events and Events.EveryOneMinute and type(Events.EveryOneMinute.Add) == "function" then
    Events.EveryOneMinute.Add(tick)
end

return Bootstrap
