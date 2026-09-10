-- The server directory can be evaluated by a connected client when a mod is
-- mounted from a shared workshop package.  Never load/register the
-- authoritative runtime on that side: doing so makes every client OnTick try
-- to own a second companion and produces a spawn/recycle storm.
local function isAuthoritativeServer()
    if type(isServer) == "function" then
        local ok, value = pcall(isServer)
        if ok then return value == true end
    end
    -- A few headless test harnesses do not provide isServer().  In that
    -- environment the server module is the only side being evaluated.
    return true
end

if not isAuthoritativeServer() then
    return { started = false, disabled = true }
end

local Config = require("GoblinSurvivor/Config")
local Runtime = require("GoblinSurvivor/GoblinRuntime")
local EventHooks = require("GoblinSurvivor/EventHooks")

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
    Runtime.tick()
    if Bootstrap.lastHeartbeat == 0 or now - Bootstrap.lastHeartbeat >= Config.heartbeatSeconds then
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
    -- Runtime owns the telemetry cadence now.  A single tick is enough to
    -- publish the first state after the server has a usable world/UDP API.
    Runtime.tick()
    Bootstrap.lastHeartbeat = monotonicSeconds()
end

function Bootstrap.start()
    if Bootstrap.started then
        return
    end
    Config.refresh()
    -- IPC/Discord/Qwen is optional; the local deterministic companion must
    -- still start when the bridge marker is absent.
    Runtime.start()
    Bootstrap.started = true
    print("[GoblinSurvivor] adapter=iso_zombie friendly=true control_ready=true")
    -- Do not query multiplayer players during this callback.  On some Build
    -- 42 server startup paths OnServerStarted is emitted before the UDP
    -- engine is fully usable; the next OnTick performs the first telemetry
    -- pass after the engine is ready.
    Bootstrap.lastHeartbeat = monotonicSeconds()
end

-- Build 42's getOnlinePlayers() is not safe during OnInitGlobalModData: the
-- server UDP engine is still nil at that point.  Start after the documented
-- server-ready event so telemetry and body discovery can use the MP API.
-- Initialization itself is safe during OnInitGlobalModData: it only loads
-- configuration, validates the bridge marker, and registers network hooks.
-- Player/UDP access is deferred to tick(), which runs after world startup.
if Events ~= nil then
    EventHooks.install("server.zombie_dead", Events.OnZombieDead, function(zombie)
        Runtime.onZombieDead(zombie)
    end)
    EventHooks.install("server.zombie_create", Events.OnZombieCreate, function(zombie)
        Runtime.onZombieCreate(zombie)
    end)
    EventHooks.install("server.zombie_update", Events.OnZombieUpdate, function(zombie)
        Runtime.onZombieUpdate(zombie)
    end)
    EventHooks.install("server.global_data_init", Events.OnInitGlobalModData, Bootstrap.start)
    EventHooks.install("server.started", Events.OnServerStarted, emitInitialTelemetry)
    EventHooks.install("server.tick", Events.OnTick, tick)
    EventHooks.install("server.minute", Events.EveryOneMinute, tick)
end

return Bootstrap
