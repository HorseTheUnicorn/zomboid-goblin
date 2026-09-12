-- Authoritative runtime for one persistent Goblin companion per online player.
local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Body = require("GoblinSurvivor/GoblinBody")
local Brain = require("GoblinSurvivor/GoblinBrain")
local Autonomy = require("GoblinSurvivor/GoblinAutonomy")
local Bridge = require("GoblinSurvivor/GoblinBridge")
local Commands = require("GoblinSurvivor/GoblinCommands")
local Telemetry = require("GoblinSurvivor/GoblinTelemetry")
local ChatBridge = require("GoblinSurvivor/ChatBridge")
local Persistence = require("GoblinSurvivor/GoblinPersistence")

local Runtime = { started = false }
local nextRosterAt = 0
local nextBrainAt = setmetatable({}, { __mode = "k" })

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
    return 0
end

local function log(text)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(text)) end
end

local function updateBody(body, timestamp)
    if not Body.isGoblin(body) or not Body.exists(body) then return end
    Body.applyInvariants(body)
    if timestamp >= (nextBrainAt[body] or 0) then
        nextBrainAt[body] = timestamp + 250
        -- Observe the owner first: movement cancels independent work before
        -- another item is taken or another construction action is committed.
        Autonomy.update(body, timestamp)
        Brain.update(body, timestamp)
        Persistence.save(body,false)
    end
    Body.clearNativeTargets(body)
end

function Runtime.start()
    if not isAuthoritativeServer() then return false end
    if Runtime.started then return true end
    if not Persistence.available() then
        if not Runtime.missingJavaLogged then
            Runtime.missingJavaLogged=true
            log("SERVER_JAVA_REQUIRED start the dedicated server with Storm; clients do not need Storm")
        end
        return false
    end
    Config.refresh()
    Spawner.load()
    pcall(IPC.initialize)
    ChatBridge.start()
    Commands.start()
    Runtime.started = true
    log("runtime ready engine=iso_zombie mode=one-goblin-per-player autonomy="
        .. tostring(Config.autonomyEnabled) .. " idle_seconds=" .. tostring(Config.autonomyIdleSeconds))
    return true
end

function Runtime.tick()
    if not isAuthoritativeServer() then return end
    if not Runtime.started then Runtime.start() end
    if not Runtime.started then return end
    if not Config.enabled then return end
    local timestamp = nowMs()
    -- Zombie events still run each update; roster scans/telemetry don't need
    -- to traverse the whole cell on every rendered server frame.
    if timestamp < nextRosterAt then return end
    nextRosterAt = timestamp + 250
    local bodies = Spawner.ensureAll(false)
    for _, body in ipairs(bodies) do updateBody(body, timestamp) end
    Bridge.tick()
    for _, body in ipairs(Spawner.allBodies()) do Body.clearNativeTargets(body) end
    Spawner.syncClientState(false)
    Spawner.syncOwnerMarkers(timestamp)
    Telemetry.write(false)
    Telemetry.writeExact(false)
end

function Runtime.onZombieCreate(zombie)
    if not isAuthoritativeServer() or not Runtime.started or not Config.enabled then return end
    if Spawner.onZombieCreate(zombie) and Body.isGoblin(zombie) then
        Body.applyInvariants(zombie)
        log("restore owner=" .. tostring(Body.owner(zombie)) .. " npc_id=" .. tostring(Body.npcId(zombie)))
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
    if not isAuthoritativeServer() or not Runtime.started or not Config.enabled then return end
    if not Body.isGoblin(zombie) then return end
    updateBody(zombie, nowMs())
end

function Runtime.snapshot()
    return Spawner.snapshotAll()
end

function Runtime.onPlayerDeath(player)
    if isAuthoritativeServer() and Runtime.started then Spawner.onPlayerDeath(player) end
end

function Runtime.save()
    if not Runtime.started or not isAuthoritativeServer() then return end
    for _,body in ipairs(Spawner.allBodies()) do Persistence.save(body,true) end
end

return Runtime
