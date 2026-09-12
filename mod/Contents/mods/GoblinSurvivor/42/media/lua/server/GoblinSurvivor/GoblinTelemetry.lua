-- Coarse telemetry for all per-player Goblin companions.
-- Exact coordinates remain isolated to the tracker stream.
local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Spawner = require("GoblinSurvivor/GoblinSpawner")

local Telemetry = { lastAt = 0, lastExactAt = 0 }

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
    local ok, list = pcall(getOnlinePlayers)
    if not ok or list == nil then return result end
    local count = type(list.size) == "function" and list:size() or #list
    for index = 0, count - 1 do
        local player = type(list.get) == "function" and list:get(index) or list[index + 1]
        if player ~= nil and type(player.getUsername) == "function" then
            local okName, name = pcall(player.getUsername, player)
            if okName and type(name) == "string" and name ~= "" then
                result[#result + 1] = { id = name, online = true }
            end
        end
    end
    return result
end

local function modeFor(snapshot)
    if snapshot == nil or snapshot.body_present ~= true then return "SAFE" end
    if snapshot.task == "ATTACK" then return "HUNT" end
    if snapshot.task == "FOLLOW" then return "PARTY" end
    return "ROAM"
end

local function coarseCompanion(snapshot)
    return {
        npc_id = snapshot.npc_id,
        owner = snapshot.owner,
        name = snapshot.name or Config.npcName,
        alive = snapshot.alive == true,
        active = true,
        body_present = snapshot.body_present == true,
        body_mode = snapshot.body_present == true and "npc" or "sensor_only",
        control_ready = snapshot.body_present == true and snapshot.humanized == true,
        npc_engine_ready = snapshot.body_present == true and snapshot.engine == "iso_zombie",
        role = Config.npcRole,
        mode = modeFor(snapshot),
        task = snapshot.task,
        physical_state = snapshot.physical_state,
        move_type = snapshot.move_type,
        combat_state = snapshot.combat_state,
        weapon_ready = snapshot.weapon_ready == true,
        visual_asset = Config.npcVisualAsset,
        visual_asset_applied = snapshot.visual_asset_applied == true,
        loot_count = snapshot.loot_count or 0,
        loot_status = snapshot.loot_status,
        work_status = snapshot.work_status,
        job_active = snapshot.job_active,
        riding = snapshot.riding,
        transport_active = snapshot.transport_active,
        transport_status = snapshot.transport_status,
        owner_idle_seconds = snapshot.owner_idle_seconds,
        job_progress = snapshot.job_progress,
        work_completed = snapshot.work_completed,
        all_skills_maxed = snapshot.all_skills_maxed,
        inventory_persisted = snapshot.inventory_persisted == true,
        inventory_error = snapshot.inventory_error,
        owner_online = snapshot.owner_online,
        autonomous = snapshot.autonomous == true,
        persisted = snapshot.persisted == true,
        generation = snapshot.generation,
        base_set = snapshot.base_set == true,
        friendly = true,
        protected = Config.protected == true,
        spawn_attempts = snapshot.spawn_attempts or 0,
        spawn_status = snapshot.spawn_detail,
        threat_level = "none",
        hunger = 0,
        thirst = 0,
        fatigue = 0,
        panic = 0,
        injury = 0
    }
end

function Telemetry.write(force)
    if not IPC.isReady() then return false end
    local timestamp = nowMs()
    if not force and timestamp - Telemetry.lastAt < (tonumber(Config.heartbeatSeconds) or 5) * 1000 then
        return false
    end
    Telemetry.lastAt = timestamp

    local snapshots = Spawner.snapshotAll()
    local companions = {}
    local npcs = {}
    for _, snapshot in ipairs(snapshots) do
        local item = coarseCompanion(snapshot)
        if item.owner_online == false and item.body_present then
            item.authority_token = require("GoblinSurvivor/Authority").issueOffline(Spawner.findByNpcId(item.npc_id))
        end
        companions[#companions + 1] = item
        npcs[#npcs + 1] = {
            npc_id = item.npc_id,
            owner = item.owner,
            name = item.name,
            role = item.role,
            alive = item.alive,
            active = item.active,
            friendly = true
        }
    end
    local primary = companions[1]
    local anyPresent = primary ~= nil

    local message = {
        protocol = Config.protocol,
        request_id = "zomboid-state",
        timestamp_ms = timestamp,
        type = "runtime.state",
        companions = companions,
        npcs = npcs,
        companion_count = #companions,
        alive = anyPresent and primary.alive or false,
        body_present = anyPresent and primary.body_present or false,
        body_mode = anyPresent and primary.body_mode or "sensor_only",
        npc_id = anyPresent and primary.npc_id or Config.npcId,
        owner = anyPresent and primary.owner or nil,
        npc_alive = anyPresent and primary.alive or false,
        npc_active = true,
        control_ready = anyPresent and primary.control_ready or false,
        npc_engine_ready = anyPresent and primary.npc_engine_ready or false,
        role = Config.npcRole,
        mode = anyPresent and primary.mode or "SAFE",
        task = anyPresent and primary.task or "FOLLOW",
        physical_state = anyPresent and primary.physical_state or "IDLE",
        move_type = anyPresent and primary.move_type or "IDLE",
        combat_state = anyPresent and primary.combat_state or "NONE",
        weapon_ready = anyPresent and primary.weapon_ready or false,
        visual_asset = Config.npcVisualAsset,
        visual_asset_applied = anyPresent and primary.visual_asset_applied or false,
        loot_count = anyPresent and primary.loot_count or 0,
        loot_status = anyPresent and primary.loot_status or nil,
        base_set = anyPresent and primary.base_set or false,
        has_food = false,
        has_water = false,
        has_medical = false,
        friendly = true,
        protected = Config.protected == true,
        threat_level = "none",
        hunger = 0,
        thirst = 0,
        fatigue = 0,
        panic = 0,
        injury = 0,
        nearby_players = onlinePlayers()
    }
    message.player_count = #message.nearby_players

    local ok = IPC.publishRuntime("zomboid-state", message)
    IPC.publishRuntime("zomboid-heartbeat", {
        protocol = Config.protocol,
        request_id = "zomboid-heartbeat",
        timestamp_ms = timestamp,
        type = "runtime.heartbeat",
        status = "safe",
        companion_count = #companions,
        body_mode = message.body_mode,
        control_ready = message.control_ready,
        npc_engine_ready = message.npc_engine_ready
    })
    return ok == true
end

function Telemetry.writeExact(force)
    if not IPC.isReady() or not Config.trackerExactTelemetry then return false end
    local timestamp = nowMs()
    if not force and timestamp - Telemetry.lastExactAt < 1000 then return false end
    Telemetry.lastExactAt = timestamp
    local entities = {}
    -- Private tracker diagnostics, never forwarded to Qwen's coarse view.
    if type(getOnlinePlayers)=="function" then
        local players=getOnlinePlayers()
        for i=0,players:size()-1 do
            local player=players:get(i)
            entities[#entities+1]={entity_id="player."..player:getUsername(),kind="player",
                x=player:getX(),y=player:getY(),z=player:getZ()}
        end
    end
    for _, snapshot in ipairs(Spawner.snapshotAll()) do
        if snapshot.body_present == true and snapshot.position ~= nil then
            entities[#entities + 1] = {
                entity_id = snapshot.npc_id,
                kind = "goblin",
                owner = snapshot.owner,
                x = snapshot.position.x,
                y = snapshot.position.y,
                z = snapshot.position.z
            }
        end
    end
    return IPC.publishRuntime("zomboid-exact-state", {
        protocol = Config.protocol,
        request_id = "zomboid-exact-state",
        timestamp_ms = timestamp,
        type = "runtime.exact_state",
        entities = entities
    })
end

return Telemetry
