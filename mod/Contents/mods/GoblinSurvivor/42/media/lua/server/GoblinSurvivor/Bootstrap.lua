-- Dedicated-server bootstrap.  Clients load only the client module.
local function isAuthoritativeServer()
    if type(isServer) == "function" then
        local ok, value = pcall(isServer)
        if ok then return value == true end
    end
    return true
end

if not isAuthoritativeServer() then
    return { started = false, disabled = true }
end

local Config = require("GoblinSurvivor/Config")
local Runtime = require("GoblinSurvivor/GoblinRuntime")
local Defense = require("GoblinSurvivor/GoblinDefense")
local EventHooks = require("GoblinSurvivor/EventHooks")

local Bootstrap = { started = false }

function Bootstrap.start()
    if Bootstrap.started then return end
    Config.refresh()
    Defense.install()
    Runtime.start()
    Bootstrap.started = true
    print("[GoblinSurvivor] mode=one-goblin-per-player friendly=true qwen=optional follow=1tile weapon=DoubleBarrelShotgun")
end

local function tick()
    if not Bootstrap.started then Bootstrap.start() end
    if Bootstrap.started then Runtime.tick() end
end

if Events ~= nil then
    EventHooks.install("server.global_data_init", Events.OnInitGlobalModData, Bootstrap.start)
    EventHooks.install("server.started", Events.OnServerStarted, tick)
    EventHooks.install("server.tick", Events.OnTick, tick)
    EventHooks.install("server.minute", Events.EveryOneMinute, tick)
    EventHooks.install("server.zombie_create", Events.OnZombieCreate, Runtime.onZombieCreate)
    EventHooks.install("server.zombie_dead", Events.OnZombieDead, Runtime.onZombieDead)
    EventHooks.install("server.zombie_update", Events.OnZombieUpdate, Runtime.onZombieUpdate)
end

return Bootstrap
