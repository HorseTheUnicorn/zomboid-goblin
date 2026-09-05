local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Persistence = require("GoblinSurvivor/Persistence")
local GoblinNPC = require("GoblinSurvivor/GoblinNPC")
local NPCRegistry = require("GoblinSurvivor/NPCRegistry")
local NpcAdapter = require("GoblinSurvivor/NpcAdapter")
local Telemetry = require("GoblinSurvivor/Telemetry")
local CommandLoop = require("GoblinSurvivor/CommandLoop")
local ChatBridge = require("GoblinSurvivor/ChatBridge")
local GSSurvivor = require("GoblinSurvivor/GSSurvivor")
local SurvivorInteraction = require("GoblinSurvivor/GSSurvivorZombieInteraction")
local DevCommands = require("GoblinSurvivor/GSSurvivorDevCommands")
local ClientSurvivorServer = require("GoblinSurvivor/ClientSurvivorServer")
local PlayerCommands = require("GoblinSurvivor/PlayerCommands")

local Bootstrap = {
    started = false,
    lastHeartbeat = 0
}

local function runningOnServer()
    -- Build 42 exposes these globals differently across the dedicated-server
    -- and local-client Lua runtimes. Prefer an explicit client result so a
    -- missing/changed isServer() global cannot make the client initialize the
    -- shared IPC bridge or register server mutation hooks.
    if type(isClient) == "function" then
        local okClient, clientValue = pcall(isClient)
        if okClient then return clientValue ~= true end
    end
    if type(isServer) == "function" then
        local okServer, serverValue = pcall(isServer)
        if okServer then return serverValue == true end
    end
    return true
end

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
    if Config.bodyMode == "client_survivor" then
        ClientSurvivorServer.tick()
    else
        -- The legacy engine owns all IsoZombie-backed bodies. The current
        -- client-survivor mode never enters this path.
        GSSurvivor.UpdateAll()
        SurvivorInteraction.update()
    end
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
    ChatBridge.start()
    if Config.bodyMode == "client_survivor" then
        ClientSurvivorServer.start()
        PlayerCommands.start()
    else
        GSSurvivor.Start()
    end
    -- The legacy /gss spawn commands call GoblinNPC.spawnGoblin(), which is
    -- intentionally IsoZombie-backed. Never register that test surface while
    -- the client-rendered survivor is the active body mode; otherwise a local
    -- operator command can reintroduce the zombie beside the spawn point.
    if Config.bodyMode ~= "client_survivor" then
        DevCommands.start()
    end
    Bootstrap.started = true
    local capabilities = NpcAdapter.capabilities()
    print("[GoblinSurvivor] adapter=" .. tostring(capabilities.selected_adapter)
        .. " friendly=" .. tostring(capabilities.friendly)
        .. " control_ready=" .. tostring(capabilities.control_ready))
    -- Do not query multiplayer players during this callback.  On some Build
    -- 42 server startup paths OnServerStarted is emitted before the UDP
    -- engine is fully usable; the next OnTick performs the first telemetry
    -- pass after the engine is ready.
    Bootstrap.lastHeartbeat = monotonicSeconds()
end

-- The local test client loads the mod package too, but Goblin's IPC, world
-- mutation, and telemetry authority belong exclusively to the server. This
-- guard prevents a client-side Bootstrap from racing the server or creating a
-- second native body in the shared local bridge directory.
if not runningOnServer() then
    return Bootstrap
end

if Events and Events.OnZombieDead and type(Events.OnZombieDead.Add) == "function" then
    Events.OnZombieDead.Add(function(zombie)
        if Config.bodyMode == "client_survivor" then return end
        GoblinNPC.onZombieDeath(zombie)
        GSSurvivor.OnDeath(zombie)
    end)
end
if Events and Events.OnZombieCreate and type(Events.OnZombieCreate.Add) == "function" then
    Events.OnZombieCreate.Add(function(zombie)
        if Config.bodyMode == "client_survivor" then return end
        NPCRegistry.onZombieCreate(zombie)
    end)
end
if Events and Events.OnZombieUpdate and type(Events.OnZombieUpdate.Add) == "function" then
    Events.OnZombieUpdate.Add(function(zombie)
        if Config.bodyMode == "client_survivor" then return end
        -- Storm may mark a fully-registered body after the engine's original
        -- OnZombieCreate callback. Give the registry a cheap adoption pass on
        -- the first update of that body.
        NPCRegistry.onZombieCreate(zombie)
        if GSSurvivor.IsManaged(zombie) then
            GSSurvivor.Update(zombie)
        else
            SurvivorInteraction.onZombieUpdate(zombie)
        end
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
