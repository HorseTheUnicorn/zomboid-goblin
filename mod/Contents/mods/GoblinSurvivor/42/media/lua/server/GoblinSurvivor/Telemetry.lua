local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Perception = require("GoblinSurvivor/Perception")
local BaseManager = require("GoblinSurvivor/BaseManager")
local GuardManager = require("GoblinSurvivor/GuardManager")
local JobManager = require("GoblinSurvivor/JobManager")
local SquadManager = require("GoblinSurvivor/SquadManager")
local ClientSurvivorServer = require("GoblinSurvivor/ClientSurvivorServer")

local Telemetry = {}

local LegacyModules
local function legacyModules()
    if LegacyModules == nil then
        LegacyModules = {
            GoblinNPC = require("GoblinSurvivor/GoblinNPC"),
            NPCRegistry = require("GoblinSurvivor/NPCRegistry"),
            NpcAdapter = require("GoblinSurvivor/NpcAdapter")
        }
    end
    return LegacyModules
end

local function clientActorMode()
    return Config.bodyMode == "client_survivor"
end

local function runtimeNpcState()
    if clientActorMode() then return ClientSurvivorServer.status() end
    return legacyModules().GoblinNPC.getGoblinState()
end

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
    local npc = runtimeNpcState()
    return IPC.publishRuntime("zomboid-heartbeat", {
        protocol = Config.protocol,
        request_id = "zomboid-heartbeat",
        timestamp_ms = nowMs(),
        type = "runtime.heartbeat",
        mod_version = "0.5.0-dev",
        survivor_engine_version = Config.survivorEngineVersion,
        protocol_version = Config.protocol,
        status = "safe",
        body_mode = npc.body_mode,
        npc_id = npc.npc_id,
        control_ready = npc.control_ready,
        npc_engine_ready = npc.npc_engine_ready,
        friendly = npc.friendly,
        protected = npc.protected,
        needs_disabled = npc.needs_disabled,
        spawn_status = npc.spawn_status,
        spawn_pending = npc.spawn_pending,
        spawn_attempts = npc.spawn_attempts
    })
end

function Telemetry.writeState()
    if not IPC.isReady() then return false end
    local npc = runtimeNpcState()
    local legacy = nil
    local zombie = nil
    if not clientActorMode() then
        legacy = legacyModules()
        zombie = legacy.GoblinNPC.findGoblin()
    end
    local perception = Perception.coarseState(zombie)
    local body = npc
    if legacy ~= nil then body = legacy.NpcAdapter.status(zombie) end
    local roster = ClientSurvivorServer.statusAll()
    if legacy ~= nil then roster = legacy.NPCRegistry.snapshot() end
    return IPC.publishRuntime("zomboid-state", {
        protocol = Config.protocol,
        request_id = "zomboid-state",
        timestamp_ms = nowMs(),
        type = "runtime.state",
        mod_version = "0.5.0-dev",
        survivor_engine_version = Config.survivorEngineVersion,
        protocol_version = Config.protocol,
        alive = npc.alive,
        body_present = npc.body_present == true,
        body_mode = npc.body_mode,
        npc_id = npc.npc_id,
        npc_alive = npc.alive,
        npc_active = npc.active,
        authority = npc.authority,
        movement_blocked = npc.movement_blocked,
        navigation_status = npc.navigation_status,
        route_remaining = npc.route_remaining,
        control_ready = npc.control_ready,
        npc_engine_ready = npc.npc_engine_ready,
        role = npc.role,
        mode = body.mode or "SAFE",
        task = body.task,
        target_player = body.target_player,
        target_npc_id = body.target_npc_id,
        threat_level = perception.threat_level or "none",
        hunger = 0,
        thirst = 0,
        fatigue = 0,
        panic = 0,
        injury = 0,
        -- The client-survivor slice does not expose hunger/thirst/inventory
        -- readiness through the snapshot yet. These values remain
        -- deliberately conservative rather than fabricated.
        weapon_ready = body.weapon_ready == true,
        firearm_type = body.firearm_type,
        weapon_policy = body.weapon_policy,
        god_mode = body.god_mode == true,
        hostile_to_zombies = body.hostile_to_zombies == true,
        body_generation = body.body_generation,
        health = body.health,
        combat_mode = body.combat_mode,
        combat_status = body.combat_status,
        combat_target_id = body.combat_target_id,
        shots_fired = body.shots_fired,
        zombies_killed = body.zombies_killed,
        incoming_hits = body.incoming_hits,
        last_kill_id = body.last_kill_id,
        death_reason = body.death_reason,
        has_food = body.has_food == true,
        has_water = body.has_water == true,
        has_medical = body.has_medical == true,
        friendly = body.friendly == true,
        protected = body.protected == true,
        needs_disabled = body.needs_disabled == true,
        spawn_status = npc.spawn_status,
        spawn_pending = npc.spawn_pending,
        spawn_attempts = npc.spawn_attempts,
        -- Diagnostic only: this is the current ordinary IsoZombie population
        -- visible to the server. Goblin's human body is never counted here.
        ordinary_zombie_count = clientActorMode()
            and ClientSurvivorServer.ordinaryZombieCount() or nil,
        base = GuardManager.snapshot(),
        jobs = JobManager.snapshot(),
        squads = SquadManager.snapshot(),
        player_count = #perception.nearby_players,
        nearby_players = perception.nearby_players,
         npcs = roster
    })
end

-- This stream is consumed by TrackerStore only. It is never inserted into
-- zomboid-state and therefore cannot enter the redacted Qwen context.
function Telemetry.writeExactState()
    if not IPC.isReady() or not Config.trackerExactTelemetry then return false end
    local entities = {}
    local base = BaseManager.snapshotExact()
    if base ~= nil then table.insert(entities, base) end
    if clientActorMode() then
        for _, state in ipairs(ClientSurvivorServer.snapshotAll()) do
            table.insert(entities, {
                entity_id = state.actor_id,
                npc_id = state.actor_id,
                kind = state.actor_id == Config.npcId and "goblin" or "survivor",
                name = state.display_name,
                role = state.role or Config.npcRole,
                x = state.x,
                y = state.y,
                z = state.z
            })
        end
    else
        for _, entity in ipairs(legacyModules().NPCRegistry.snapshotExact()) do
            if entity.npc_id == Config.npcId then
                entity.kind = "goblin"
            end
            table.insert(entities, entity)
        end
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
