-- Coarse runtime telemetry for the Python/Qwen bridge.
-- Exact world coordinates are kept on the separate tracker stream and are
-- never included in the model-bound state message.
local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Brain = require("GoblinSurvivor/GoblinBrain")

local Telemetry = { lastAt = 0 }

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
            if okName and type(name) == "string" and #name > 0 and #name <= 96 then
                result[#result + 1] = { id = name, online = true }
            end
        end
    end
    return result
end

local function modeFor(snapshot)
    if snapshot == nil or snapshot.body_present ~= true then return "SAFE" end
    if snapshot.task == "FOLLOW" or snapshot.task == "RETURN_TO_OWNER" then return "PARTY" end
    if snapshot.task == "ATTACK" then return "HUNT" end
    return "ROAM"
end

function Telemetry.write(force)
    if not IPC.isReady() then return false end
    local timestamp = nowMs()
    if not force and timestamp - Telemetry.lastAt < Config.heartbeatSeconds * 1000 then
        return false
    end
    Telemetry.lastAt = timestamp
    local snapshot = Spawner.snapshot()
    local brain = Brain.snapshot(Spawner.find())
    local nearbyPlayers = onlinePlayers()
    local bodyPresent = snapshot.body_present == true
    local message = {
        protocol = Config.protocol,
        request_id = "zomboid-state",
        timestamp_ms = timestamp,
        type = "runtime.state",
        alive = snapshot.alive == true,
        body_present = bodyPresent,
        body_mode = bodyPresent and "npc" or "sensor_only",
        npc_id = Config.npcId,
        entity_class = snapshot.entity_class,
        engine = snapshot.engine,
        npc_alive = snapshot.alive == true,
        npc_active = true,
        control_ready = bodyPresent and snapshot.humanized == true,
        npc_engine_ready = bodyPresent and snapshot.engine == "iso_zombie",
        role = Config.npcRole,
        mode = modeFor(snapshot),
        task = snapshot.task,
        physical_state = snapshot.physical_state,
        move_type = snapshot.move_type,
        combat_state = snapshot.combat_state,
        weapon_ready = snapshot.weapon_ready == true,
        visual_asset = snapshot.visual_asset,
        visual_asset_applied = snapshot.visual_asset_applied == true,
        melee_attacks = snapshot.melee_attacks or 0,
        melee_kills = snapshot.melee_kills or 0,
        loot_count = snapshot.loot_count or 0,
        loot_status = snapshot.loot_status,
        has_food = false,
        has_water = false,
        has_medical = false,
        friendly = bodyPresent,
        protected = Config.protected == true,
        spawn_pending = snapshot.spawn_pending == true,
        spawn_attempts = snapshot.spawn_attempts,
        spawn_status = snapshot.spawn_detail,
        threat_level = "none",
        hunger = 0,
        thirst = 0,
        fatigue = 0,
        panic = 0,
        injury = 0,
        nearby_players = nearbyPlayers,
        player_count = #nearbyPlayers
    }
    if brain ~= nil and brain.movement ~= nil then
        message.path_status = brain.movement.goal ~= nil and "active" or "idle"
    end
    local ok = IPC.publishRuntime("zomboid-state", message)
    IPC.publishRuntime("zomboid-heartbeat", {
        protocol = Config.protocol,
        request_id = "zomboid-heartbeat",
        timestamp_ms = timestamp,
        type = "runtime.heartbeat",
        status = "safe",
        body_mode = message.body_mode,
        npc_id = Config.npcId,
        engine = message.engine,
        control_ready = message.control_ready,
        npc_engine_ready = message.npc_engine_ready,
        spawn_status = message.spawn_status,
        spawn_pending = message.spawn_pending,
        spawn_attempts = message.spawn_attempts
    })
    return ok == true
end

function Telemetry.writeExact(force)
    if not IPC.isReady() or not Config.trackerExactTelemetry then return false end
    local timestamp = nowMs()
    if not force and timestamp - (Telemetry.lastExactAt or 0) < 1000 then return false end
    Telemetry.lastExactAt = timestamp
    local snapshot = Spawner.snapshot()
    local entities = {}
    if snapshot.position ~= nil and snapshot.body_present == true then
        entities[#entities + 1] = {
            entity_id = Config.npcId,
            kind = "goblin",
            x = snapshot.position.x,
            y = snapshot.position.y,
            z = snapshot.position.z
        }
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
