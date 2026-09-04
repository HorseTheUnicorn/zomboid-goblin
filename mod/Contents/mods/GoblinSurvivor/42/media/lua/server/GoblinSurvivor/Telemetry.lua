local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local GoblinNPC = require("GoblinSurvivor/GoblinNPC")
local Perception = require("GoblinSurvivor/Perception")
local BaseManager = require("GoblinSurvivor/BaseManager")
local GuardManager = require("GoblinSurvivor/GuardManager")
local JobManager = require("GoblinSurvivor/JobManager")
local SquadManager = require("GoblinSurvivor/SquadManager")

local Telemetry = {}

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
end

local function onlinePlayers()
    local result = {}
    if type(getOnlinePlayers) ~= "function" then return result end
    local ok, players = pcall(getOnlinePlayers)
    if not ok or players == nil then return result end
    local count = type(players.size) == "function" and players:size() or #players
    for index = 0, count - 1 do
        local player = type(players.get) == "function" and players:get(index) or players[index + 1]
        if player ~= nil then
            local username = type(player.getUsername) == "function" and player:getUsername() or ""
            if type(username) == "string" and #username > 0 and #username <= 96 then
                table.insert(result, { id = username, online = true })
            end
        end
    end
    return result
end

local function position(object)
    if object == nil or type(object.getX) ~= "function"
        or type(object.getY) ~= "function" or type(object.getZ) ~= "function" then
        return nil
    end
    return { x = object:getX(), y = object:getY(), z = object:getZ() }
end

function Telemetry.writeHeartbeat()
    if not IPC.isReady() then return false end
    local npc = GoblinNPC.getGoblinState()
    return IPC.publishRuntime("zomboid-heartbeat", {
        protocol = Config.protocol,
        request_id = "zomboid-heartbeat",
        timestamp_ms = nowMs(),
        type = "runtime.heartbeat",
        status = "safe",
        body_mode = npc.body_mode,
        npc_id = npc.npc_id,
        control_ready = npc.control_ready,
        npc_engine_ready = npc.npc_engine_ready,
        spawn_status = npc.spawn_status,
        spawn_pending = npc.spawn_pending,
        spawn_attempts = npc.spawn_attempts
    })
end

function Telemetry.writeState()
    if not IPC.isReady() then return false end
    local npc = GoblinNPC.getGoblinState()
    local perception = Perception.coarseState(GoblinNPC.findGoblin())
    return IPC.publishRuntime("zomboid-state", {
        protocol = Config.protocol,
        request_id = "zomboid-state",
        timestamp_ms = nowMs(),
        type = "runtime.state",
        alive = npc.alive,
        body_present = npc.alive,
        body_mode = npc.body_mode,
        npc_id = npc.npc_id,
        npc_alive = npc.alive,
        npc_active = npc.active,
        control_ready = npc.control_ready,
        npc_engine_ready = npc.npc_engine_ready,
        role = npc.role,
        mode = "ROAM",
        threat_level = perception.threat_level or "none",
        hunger = 0,
        thirst = 0,
        fatigue = 0,
        panic = 0,
        injury = 0,
        weapon_ready = true,
        has_food = true,
        has_water = true,
        has_medical = true,
        spawn_status = npc.spawn_status,
        spawn_pending = npc.spawn_pending,
        spawn_attempts = npc.spawn_attempts,
        base = GuardManager.snapshot(),
        jobs = JobManager.snapshot(),
        squads = SquadManager.snapshot(),
        player_count = #perception.nearby_players,
        nearby_players = perception.nearby_players
    })
end

-- This stream is consumed by TrackerStore only. It is never inserted into
-- zomboid-state and therefore cannot enter the redacted Qwen context.
function Telemetry.writeExactState()
    if not IPC.isReady() or not Config.trackerExactTelemetry then return false end
    local entities = {}
    local base = BaseManager.snapshotExact()
    if base ~= nil then table.insert(entities, base) end
    local zombie = GoblinNPC.findGoblin()
    local point = position(zombie)
    if point ~= nil then
        point.npc_id = Config.npcId
        point.kind = "goblin"
        point.name = Config.npcName
        table.insert(entities, point)
    end
    if type(getOnlinePlayers) == "function" then
        local ok, players = pcall(getOnlinePlayers)
        if ok and players ~= nil then
            local count = type(players.size) == "function" and players:size() or #players
            for index = 0, count - 1 do
                local player = type(players.get) == "function" and players:get(index) or players[index + 1]
                local playerPoint = position(player)
                local username = player and type(player.getUsername) == "function" and player:getUsername() or ""
                if playerPoint ~= nil and type(username) == "string" and #username > 0 and #username <= 96 then
                    playerPoint.entity_id = username
                    playerPoint.kind = "player"
                    table.insert(entities, playerPoint)
                end
            end
        end
    end
    return IPC.publishRuntime("zomboid-exact-state", {
        protocol = Config.protocol,
        request_id = "zomboid-exact-state",
        timestamp_ms = nowMs(),
        type = "runtime.exact_state",
        entities = entities
    })
end

return Telemetry
