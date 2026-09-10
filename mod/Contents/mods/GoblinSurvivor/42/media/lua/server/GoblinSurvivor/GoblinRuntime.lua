-- Authoritative server runtime for one persistent Goblin IsoZombie.
local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Body = require("GoblinSurvivor/GoblinBody")
local Brain = require("GoblinSurvivor/GoblinBrain")
local Bridge = require("GoblinSurvivor/GoblinBridge")
local Commands = require("GoblinSurvivor/GoblinCommands")
local Telemetry = require("GoblinSurvivor/GoblinTelemetry")
local ChatBridge = require("GoblinSurvivor/ChatBridge")

local Runtime = { started = false, lastUpdateAt = 0 }

local function isAuthoritativeServer()
    if type(isServer) == "function" then
        local ok, value = pcall(isServer)
        if ok then return value == true end
    end
    return true
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function log(message)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(message)) end
end

function Runtime.start()
    if not isAuthoritativeServer() then return false end
    if Runtime.started then return true end
    Config.refresh()
    Spawner.load()
    -- The bridge is optional; body startup must not depend on the Qwen process.
    pcall(IPC.initialize)
    ChatBridge.start()
    Commands.start()
    Runtime.started = true
    log("Goblin companion runtime ready engine=iso_zombie npc_id=" .. Config.npcId)
    return true
end

function Runtime.tick()
    if not isAuthoritativeServer() then return end
    if not Runtime.started then Runtime.start() end
    if not Config.enabled then return end
    local timestamp = nowMs()
    local body = Spawner.ensure(false)
    if body ~= nil and Body.isGoblin(body) then
        local data = Body.data(body)
        local nextUpdate = data ~= nil and tonumber(data.GoblinNextBrainAt) or 0
        if timestamp >= nextUpdate then
            if data ~= nil then data.GoblinNextBrainAt = timestamp + 250 end
            Brain.update(body, timestamp)
        end
        -- Brain state is semantic and never uses the native hostile target;
        -- clear again after it runs so the audit/replication snapshot cannot
        -- observe a target repopulated by the engine during this tick.
        Body.clearNativeTargets(body)
        Body.auditAnimation(body)
    end
    -- Commands are high-level and may change the task for the next update;
    -- process them after the body has been ensured, never before spawning.
    Bridge.tick()
    -- Keep the client-facing envelope aligned with the authoritative body
    -- after brain/bridge changes.  The spawner deduplicates by state
    -- signature, so this is not a per-frame network broadcast.
    if body ~= nil and Body.isGoblin(body) then
        Spawner.syncClientState(body, false)
    end
    Telemetry.write(false)
    Telemetry.writeExact(false)
end

function Runtime.onZombieCreate(zombie)
    if not isAuthoritativeServer() then return end
    if not Runtime.started or not Config.enabled then return end
    if Spawner.onZombieCreate(zombie) and Body.isGoblin(zombie) then
        Body.applyInvariants(zombie, false)
        log("RESTORE id=" .. Config.npcId .. " generation="
            .. tostring(Body.data(zombie).GoblinGeneration))
    end
end

function Runtime.onZombieDead(zombie)
    if not isAuthoritativeServer() then return end
    if Spawner.onZombieDead(zombie) then
        Telemetry.write(true)
        Telemetry.writeExact(true)
    end
end

function Runtime.onZombieUpdate(zombie)
    if not isAuthoritativeServer() then return end
    if not Runtime.started or not Config.enabled or not Body.isGoblin(zombie) then return end
    -- This is intentionally outside the 250 ms brain throttle.  Native
    -- zombie targeting runs every engine tick and can otherwise send the
    -- companion back through LungeState/AttackState between brain updates.
    Body.clearNativeTargets(zombie)
    local timestamp = nowMs()
    local data = Body.data(zombie)
    local nextUpdate = data ~= nil and tonumber(data.GoblinNextBrainAt) or 0
    if timestamp < nextUpdate then return end
    if data ~= nil then data.GoblinNextBrainAt = timestamp + 250 end
    Brain.update(zombie, timestamp)
    Body.clearNativeTargets(zombie)
    Body.auditAnimation(zombie)
end

function Runtime.snapshot()
    return Spawner.snapshot()
end

return Runtime
