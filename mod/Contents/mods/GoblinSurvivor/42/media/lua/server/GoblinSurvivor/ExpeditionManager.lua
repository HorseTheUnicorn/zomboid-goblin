-- Durable survivor expeditions.
--
-- The Java authority owns real world-item pickup, body inventory, and
-- delivery.  This module owns the durable policy around that work: Goblin's
-- idle hand-off, deterministic outbound points, the return phase, and the
-- bounded cargo ledger used while no client has the world loaded.
local Config = require("GoblinSurvivor/Config")
local BaseManager = require("GoblinSurvivor/BaseManager")

local ExpeditionManager = {}

local MAX_OFFLINE_CARGO_ITEMS = 128
local MAX_OFFLINE_CARGO_TYPES = 64
local OFFLINE_WORK_INTERVAL_MS = 15000
local MAX_OFFLINE_CATCHUP_MS = 300000
local IDLE_BEFORE_EXPEDITION_MS = 20000
local PLAYER_MOVE_THRESHOLD = 0.75

local EXPEDITION_JOBS = {
    LOOT = true,
    SCAVENGE = true,
    HAULER = true,
    FARMER = true,
    SCOUT = true,
    MEDIC = true
}

-- These are only the fallback entries used when the server is running with
-- no loaded player/world.  Real online expeditions collect the actual item
-- types found in world objects and containers instead of inventing a fixed
-- reward list.  Every fallback item is a normal Base.* item and is validated
-- again by the Java materializer before it reaches a player inventory.
local OFFLINE_CATALOG = {
    GENERAL = {
        "Base.CannedBeans", "Base.WaterBottle", "Base.Bandage",
        "Base.Nails", "Base.Plank", "Base.Hammer", "Base.Screwdriver",
        "Base.TinOpener", "Base.Saw", "Base.RippedSheets",
        "Base.308Bullets", "Base.M14Clip"
    },
    MEDIC = {
        "Base.Bandage", "Base.Disinfectant", "Base.AlcoholWipes",
        "Base.Pills", "Base.WaterBottle"
    },
    FARMER = {
        "Base.Carrot", "Base.Cabbage", "Base.Tomato", "Base.HandShovel",
        "Base.Fertilizer", "Base.WaterBottle", "Base.Nails"
    }
}

local idleSamples = {}

local function finite(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function validPoint(value)
    return type(value) == "table" and finite(value.x) and finite(value.y)
        and finite(value.z)
end

local function validItemType(value)
    return type(value) == "string" and #value > 0 and #value <= 96
        and string.match(value, "^Base%.[A-Za-z0-9_]+$") ~= nil
end

local function normalizedJob(job)
    return string.upper(tostring(job or ""))
end

local function integer(value, fallback, minimum, maximum)
    local number = tonumber(value)
    if number == nil or math.floor(number) ~= number
        or number < minimum or number > maximum then
        return fallback
    end
    return number
end

local function stableHash(value)
    local hash = 17
    local text = tostring(value or "")
    for index = 1, #text do
        hash = (hash * 31 + string.byte(text, index)) % 2147483647
    end
    return hash
end

local function cargoTotal(cargo)
    if type(cargo) ~= "table" then return 0 end
    local total = 0
    for itemType, count in pairs(cargo) do
        if validItemType(itemType) then
            total = total + integer(count, 0, 0, MAX_OFFLINE_CARGO_ITEMS)
        end
    end
    return math.min(total, MAX_OFFLINE_CARGO_ITEMS)
end

local function cargoTypeCount(cargo)
    if type(cargo) ~= "table" then return 0 end
    local total = 0
    for itemType, count in pairs(cargo) do
        if validItemType(itemType) and integer(count, 0, 0, MAX_OFFLINE_CARGO_ITEMS) > 0 then
            total = total + 1
        end
    end
    return math.min(total, MAX_OFFLINE_CARGO_TYPES)
end

local function copyCargo(cargo)
    local result = {}
    if type(cargo) ~= "table" then return result end
    local total = 0
    local types = 0
    for itemType, count in pairs(cargo) do
        if validItemType(itemType) and types < MAX_OFFLINE_CARGO_TYPES then
            local bounded = integer(count, 0, 0, MAX_OFFLINE_CARGO_ITEMS - total)
            if bounded > 0 then
                result[itemType] = bounded
                total = total + bounded
                types = types + 1
                if total >= MAX_OFFLINE_CARGO_ITEMS then break end
            end
        end
    end
    return result
end

function ExpeditionManager.isExpeditionJob(job)
    return EXPEDITION_JOBS[normalizedJob(job)] == true
end

function ExpeditionManager.prepare(state)
    if type(state) ~= "table" then return false end
    local phase = normalizedJob(state.expedition_phase)
    if phase ~= "OUTBOUND" and phase ~= "RETURNING"
        and phase ~= "FOLLOW" then
        phase = state.actor_id == Config.npcId and "FOLLOW" or "OUTBOUND"
    end
    state.expedition_phase = phase
    state.expedition_round = integer(state.expedition_round, 0, 0, 2147483647)
    state.offline_cargo = copyCargo(state.offline_cargo)
    state.offline_work_ms = integer(state.offline_work_ms, 0, 0, MAX_OFFLINE_CATCHUP_MS)
    state.offline_last_ms = finite(state.offline_last_ms) and state.offline_last_ms or 0
    state.cargo_count = math.max(0, integer(state.cargo_count, 0, 0, 4096))
    state.cargo_types = math.max(0, integer(state.cargo_types, 0, 0, MAX_OFFLINE_CARGO_TYPES))
    state.auto_expedition = state.auto_expedition == true
    state.return_to_follow = state.return_to_follow == true
    return true
end

local function fallbackOrigin(state, origin)
    if validPoint(origin) then
        return { x = origin.x, y = origin.y, z = origin.z }
    end
    if type(state) == "table" and finite(state.home_x)
        and finite(state.home_y) and finite(state.home_z) then
        return { x = state.home_x, y = state.home_y, z = state.home_z }
    end
    return nil
end

local function calculateOutboundPoint(state, origin)
    origin = fallbackOrigin(state, origin)
    if origin == nil then return nil end
    local hash = stableHash(state.actor_id)
    local round = integer(state.expedition_round, 0, 0, 2147483647)
    local angle = ((hash % 360) + (round * 73) % 360) * math.pi / 180
    local radius = 22 + (hash % 9)
    local point = {
        x = origin.x + math.cos(angle) * radius,
        y = origin.y + math.sin(angle) * radius,
        z = origin.z
    }
    state.expedition_target = point
    return point
end

function ExpeditionManager.destinationFor(state, job, origin)
    if not ExpeditionManager.prepare(state) then return nil end
    local normalized = normalizedJob(job or state.job)
    if normalized == "GUARD" then
        if not validPoint(state.guard_post)
            and finite(state.guard_post_x) and finite(state.guard_post_y)
            and finite(state.guard_post_z) then
            state.guard_post = {
                x = state.guard_post_x,
                y = state.guard_post_y,
                z = state.guard_post_z
            }
        end
        if validPoint(state.guard_post) then
            return {
                x = state.guard_post.x,
                y = state.guard_post.y,
                z = state.guard_post.z
            }
        end
        return fallbackOrigin(state, origin)
    end
    if not ExpeditionManager.isExpeditionJob(normalized) then return nil end
    if state.expedition_phase == "RETURNING" then
        return fallbackOrigin(state, origin)
    end
    if validPoint(state.expedition_target) then
        return {
            x = state.expedition_target.x,
            y = state.expedition_target.y,
            z = state.expedition_target.z
        }
    end
    return calculateOutboundPoint(state, origin)
end

function ExpeditionManager.resetAssignment(state, job)
    if not ExpeditionManager.prepare(state) then return false end
    state.job = normalizedJob(job)
    -- Any explicit in-game assignment overrides Goblin's idle automation.
    -- The command remains in force until another command (follow, hold,
    -- home, or a different job) changes it.
    state.auto_expedition = false
    state.return_to_follow = false
    state.guard_patrol_index = 0
    state.guard_post = nil
    state.guard_post_x = nil
    state.guard_post_y = nil
    state.guard_post_z = nil
    if not ExpeditionManager.isExpeditionJob(state.job) then
        state.expedition_phase = "OUTBOUND"
        state.expedition_target = nil
        state.return_to_follow = false
        return true
    end
    if cargoTotal(state.offline_cargo) > 0 or (state.cargo_count or 0) > 0 then
        state.expedition_phase = "RETURNING"
        state.work_status = "returning_with_cargo"
    else
        state.expedition_phase = "OUTBOUND"
        state.expedition_target = nil
    end
    return true
end

function ExpeditionManager.exportCargo(state)
    if type(state) ~= "table" then return {} end
    return copyCargo(state.offline_cargo ~= nil and state.offline_cargo or state)
end

function ExpeditionManager.importCargo(value)
    return copyCargo(value)
end

function ExpeditionManager.mergeCargo(state, value)
    if type(state) ~= "table" or type(value) ~= "table" then return false end
    local merged = copyCargo(state.offline_cargo)
    for itemType, count in pairs(copyCargo(value)) do
        local current = integer(merged[itemType], 0, 0, MAX_OFFLINE_CARGO_ITEMS)
        local bounded = integer(count, 0, 0, MAX_OFFLINE_CARGO_ITEMS - cargoTotal(merged))
        if bounded > 0 then merged[itemType] = current + bounded end
        if cargoTotal(merged) >= MAX_OFFLINE_CARGO_ITEMS then break end
    end
    state.offline_cargo = copyCargo(merged)
    return true
end

function ExpeditionManager.cargoSummary(state)
    if type(state) ~= "table" then return 0, 0 end
    return cargoTotal(state.offline_cargo), cargoTypeCount(state.offline_cargo)
end

local function addOfflineItem(state, itemType)
    if not validItemType(itemType) then return false end
    local cargo = state.offline_cargo
    local total = cargoTotal(cargo)
    local existing = integer(cargo[itemType], 0, 0, MAX_OFFLINE_CARGO_ITEMS)
    if total >= MAX_OFFLINE_CARGO_ITEMS
        or (existing == 0 and cargoTypeCount(cargo) >= MAX_OFFLINE_CARGO_TYPES) then
        return false
    end
    cargo[itemType] = existing + 1
    return true
end

local function catalogFor(job)
    local normalized = normalizedJob(job)
    if normalized == "MEDIC" then return OFFLINE_CATALOG.MEDIC end
    if normalized == "FARMER" then return OFFLINE_CATALOG.FARMER end
    return OFFLINE_CATALOG.GENERAL
end

function ExpeditionManager.tickOffline(states, nowMs)
    if type(states) ~= "table" or not finite(nowMs) then return false end
    local changed = false
    for _, state in ipairs(states) do
        if type(state) == "table" then
            ExpeditionManager.prepare(state)
            local job = normalizedJob(state.job)
            local eligible = state.control_mode == "JOB"
                and ExpeditionManager.isExpeditionJob(job)
            if state.actor_id == Config.npcId and state.manual_control ~= true
                and state.auto_expedition ~= true then
                eligible = false
            end
            if eligible then
                local last = state.offline_last_ms
                if last <= 0 or nowMs < last then last = nowMs end
                local delta = math.min(MAX_OFFLINE_CATCHUP_MS, nowMs - last)
                state.offline_last_ms = nowMs
                state.offline_work_ms = math.min(
                    MAX_OFFLINE_CATCHUP_MS,
                    state.offline_work_ms + math.max(0, delta)
                )
                local catalog = catalogFor(job)
                while state.offline_work_ms >= OFFLINE_WORK_INTERVAL_MS do
                    state.offline_work_ms = state.offline_work_ms - OFFLINE_WORK_INTERVAL_MS
                    local round = integer(state.expedition_round, 0, 0, 2147483647)
                    local index = (stableHash(state.actor_id) + round) % #catalog + 1
                    local itemType = catalog[index]
                    if not addOfflineItem(state, itemType) then
                        state.work_status = "offline_cargo_full"
                        break
                    end
                    state.work_count = math.max(0, integer(state.work_count, 0, 0, 2147483647)) + 1
                    state.last_work_item = itemType
                    state.work_status = "offline_expedition"
                    state.expedition_phase = "RETURNING"
                    changed = true
                end
                local offlineCount = cargoTotal(state.offline_cargo)
                state.cargo_count = math.max(state.cargo_count or 0, offlineCount)
                state.cargo_types = cargoTypeCount(state.offline_cargo)
            else
                -- Do not accumulate offline time while a physical body is
                -- being serviced online.  The next empty-player interval
                -- starts from a fresh, persisted timestamp.
                state.offline_last_ms = nowMs
                state.offline_work_ms = 0
            end
        end
    end
    return changed
end

local function playerPoint(player)
    if player == nil or type(player.getX) ~= "function"
        or type(player.getY) ~= "function" or type(player.getZ) ~= "function" then
        return nil
    end
    local ok, x, y, z = pcall(function()
        return player:getX(), player:getY(), player:getZ()
    end)
    if not ok then return nil end
    local point = { x = x, y = y, z = z }
    return validPoint(point) and point or nil
end

local function playerName(player)
    if player == nil or type(player.getUsername) ~= "function" then return "player" end
    local ok, name = pcall(player.getUsername, player)
    return ok and type(name) == "string" and name or "player"
end

local function setAutomaticFollow(state, player)
    local point = playerPoint(player)
    if point == nil then return false end
    state.control_mode = "FOLLOW"
    state.task = "FOLLOW"
    state.mode = "PARTY"
    state.job = nil
    state.target_username = playerName(player)
    state.follow_username = state.target_username
    state.target_actor_id = nil
    state.destination = nil
    state.arrival_task = nil
    state.expedition_phase = "FOLLOW"
    state.expedition_target = nil
    state.auto_expedition = false
    state.return_to_follow = false
    state.work_status = "following"
    return true
end

local function startAutomaticExpedition(state)
    state.control_mode = "JOB"
    state.task = "JOB_SCAVENGE"
    state.mode = "WORK"
    state.job = "SCAVENGE"
    state.target_username = nil
    state.follow_username = nil
    state.target_actor_id = nil
    state.destination = nil
    state.arrival_task = nil
    state.auto_expedition = true
    state.return_to_follow = false
    state.expedition_target = nil
    local loaded = cargoTotal(state.offline_cargo) > 0
        or (state.cargo_count or 0) > 0
    state.expedition_phase = loaded and "RETURNING" or "OUTBOUND"
    state.work_status = "player_idle_expedition"
    return true
end

-- Goblin follows by default.  Once the player has stopped moving for the
-- bounded idle window, an automatic, non-manual scavenging order is issued.
-- Movement immediately recalls an empty Goblin; a loaded Goblin finishes the
-- return leg before the follow target is rebound.
function ExpeditionManager.updateGoblinIdle(state, player, nowMs)
    if type(state) ~= "table" or player == nil or not finite(nowMs)
        or state.actor_id ~= Config.npcId then return false end
    ExpeditionManager.prepare(state)
    if state.manual_control == true then return false end
    local point = playerPoint(player)
    if point == nil then return false end
    local name = playerName(player)
    -- A cold-booted roster has no player username to restore. Rebind Goblin
    -- to the first connected player here while keeping the automatic policy
    -- intact; this is deliberately not the manual FOLLOW command.
    local rebound = false
    if state.control_mode == "FOLLOW"
        and (state.follow_username ~= name or state.target_username ~= name) then
        state.follow_username = name
        state.target_username = name
        state.work_status = "following"
        rebound = true
    end
    local sample = idleSamples[name]
    local movedThisTick = false
    if sample == nil then
        sample = { point = point, lastMoveMs = nowMs, idleSinceMs = nowMs }
        idleSamples[name] = sample
    else
        local previous = sample.point
        local moved = previous == nil
            or math.abs(previous.x - point.x) > PLAYER_MOVE_THRESHOLD
            or math.abs(previous.y - point.y) > PLAYER_MOVE_THRESHOLD
            or math.abs(previous.z - point.z) > 0.1
        if moved then
            movedThisTick = true
            sample.lastMoveMs = nowMs
            sample.idleSinceMs = nowMs
        elseif sample.idleSinceMs == nil then
            sample.idleSinceMs = nowMs
        end
        sample.point = point
    end

    local isAuto = state.auto_expedition == true
    local playerMoving = movedThisTick
    if isAuto and playerMoving then
        local loaded = (state.cargo_count or 0) > 0
            or cargoTotal(state.offline_cargo) > 0
            or state.expedition_phase == "RETURNING"
        if loaded then
            state.return_to_follow = true
            state.expedition_phase = "RETURNING"
            state.work_status = "returning_to_player"
        else
            return setAutomaticFollow(state, player)
        end
        return true
    end

    if not isAuto and state.control_mode == "FOLLOW"
        and sample.idleSinceMs ~= nil
        and nowMs - sample.idleSinceMs >= IDLE_BEFORE_EXPEDITION_MS then
        return startAutomaticExpedition(state)
    end
    if isAuto and state.return_to_follow
        and state.expedition_phase == "OUTBOUND"
        and (state.cargo_count or 0) <= 0
        and cargoTotal(state.offline_cargo) <= 0 then
        return setAutomaticFollow(state, player)
    end
    return rebound
end

function ExpeditionManager.snapshot(state)
    if type(state) ~= "table" then return nil end
    ExpeditionManager.prepare(state)
    local offlineCount, offlineTypes = ExpeditionManager.cargoSummary(state)
    return {
        phase = state.expedition_phase,
        automatic = state.auto_expedition == true,
        return_to_follow = state.return_to_follow == true,
        cargo_count = state.cargo_count or offlineCount,
        cargo_types = math.max(state.cargo_types or 0, offlineTypes),
        offline_cargo_count = offlineCount,
        offline_cargo_types = offlineTypes,
        work_status = state.work_status
    }
end

return ExpeditionManager
