-- Optional Qwen/Discord command bridge for the rebuilt companion.
--
-- The bridge accepts only the existing typed, high-level command envelope.
-- Exact path nodes, animation names, and per-frame movement never cross this
-- boundary.  When the bridge is absent, the in-game developer commands and
-- the default FOLLOW task remain fully deterministic and usable.
local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Net = require("GoblinSurvivor/Net")
local Authority = require("GoblinSurvivor/Authority")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Brain = require("GoblinSurvivor/GoblinBrain")

local Bridge = { seen = {}, order = {}, maxSeen = 2048 }

local actions = {
    NOOP = true, WAIT = true, SAY = true, MOVE_TO = true, FOLLOW = true,
    FOLLOW_GOBLIN = true, HOLD_POSITION = true, REGROUP = true, SEARCH = true,
    SCAVENGE = true, LOOT_AREA = true, RETREAT = true, FLEE = true,
    REST = true, GO_HOME = true, RETURN_TO_BASE = true, ATTACK = true,
    DEFEND_PLAYER = true, DEFEND_AREA = true, GUARD = true, PATROL = true,
    CLEAR_BUILDING = true, EQUIP = true, LOOT = true
}

local movementActions = {
    MOVE_TO = true, FOLLOW = true, FOLLOW_GOBLIN = true, HOLD_POSITION = true,
    REGROUP = true, SEARCH = true, SCAVENGE = true, LOOT_AREA = true,
    RETREAT = true, FLEE = true, REST = true, GO_HOME = true,
    RETURN_TO_BASE = true, DEFEND_PLAYER = true, DEFEND_AREA = true,
    GUARD = true, PATROL = true, CLEAR_BUILDING = true, LOOT = true
}

local allowedKeys = {
    protocol = true, request_id = true, timestamp_ms = true, type = true,
    npc_id = true, action = true, priority = true, reason = true, text = true,
    target = true, item = true, loot_focus = true, authority_token = true,
    controller_action = true
}

local targetKeys = { kind = true, name = true, player = true, label = true }
local itemKeys = { name = true, count = true, category = true }

local function log(message)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(message)) end
end

local function safeText(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and string.find(value, "[%c]", 1) == nil
        and string.find(string.lower(value), "coordinates", 1, true) == nil
        and string.find(value, "[xyzXYZ]%s*=%s*[-+]?%d", 1) == nil
end

local function validTarget(target)
    if type(target) ~= "table" then return false end
    for key in pairs(target) do
        if type(key) ~= "string" or not targetKeys[string.lower(key)] then return false end
    end
    local kind = string.lower(tostring(target.kind or ""))
    local allowed = {
        nearby_threat = true, player = true, home_base = true, area = true,
        nearby_building = true, named_location = true, current_position = true,
        escape_route = true, goblin = true, base = true
    }
    if not allowed[kind] then return false end
    return safeText(target.name or target.label or target.player, 96)
end

local function valid(message)
    if type(message) ~= "table" or not Net.safeTable(message) then return false end
    for key in pairs(message) do
        if type(key) ~= "string" or not allowedKeys[string.lower(key)] then return false end
    end
    if type(message.action) ~= "string" then return false end
    local action = string.upper(message.action)
    if action ~= message.action or not actions[action] then return false end
    if message.npc_id ~= Config.npcId then return false end
    if message.priority ~= nil and (type(message.priority) ~= "number"
        or math.floor(message.priority) ~= message.priority or message.priority < 0
        or message.priority > 3) then return false end
    if message.reason ~= nil and not safeText(message.reason, 240) then return false end
    if message.text ~= nil and not safeText(message.text, 240) then return false end
    if message.loot_focus ~= nil and not safeText(message.loot_focus, 32) then return false end
    if message.action == "SAY" and message.text == nil then return false end
    if message.target ~= nil and not validTarget(message.target) then return false end
    if message.item ~= nil and type(message.item) ~= "table" then return false end
    if message.item ~= nil then
        for key in pairs(message.item) do
            if type(key) ~= "string" or not itemKeys[string.lower(key)] then return false end
        end
        if not safeText(message.item.name, 96) then return false end
        if message.item.category ~= nil and not safeText(message.item.category, 64) then
            return false
        end
        if message.item.count ~= nil and (type(message.item.count) ~= "number"
            or math.floor(message.item.count) ~= message.item.count
            or message.item.count < 1 or message.item.count > 10) then
            return false
        end
    end
    if message.action == "EQUIP" then
        if type(message.item) ~= "table" or message.item.name ~= Config.weaponType then
            return false
        end
    end
    if message.authority_token ~= nil and not Net.safeId(message.authority_token, 128) then
        return false
    end
    if message.controller_action ~= nil and not Net.safeTable(message.controller_action) then
        return false
    end
    if Authority.requires(message.action) and not Authority.consume(message) then return false end
    return true
end

local function remember(requestId)
    if Bridge.seen[requestId] then return false end
    Bridge.seen[requestId] = true
    Bridge.order[#Bridge.order + 1] = requestId
    if #Bridge.order > Bridge.maxSeen then
        Bridge.seen[table.remove(Bridge.order, 1)] = nil
    end
    return true
end

local function normalizedMessage(message)
    local action = string.upper(tostring(message.action))
    if action == "SAY" then return message end
    if action == "EQUIP" then return message end
    if action == "ATTACK" then return message end
    if action == "LOOT" or action == "LOOT_AREA" or action == "SCAVENGE" then
        return {
            action = "LOOT",
            loot_focus = message.loot_focus,
            target = message.target
        }
    end
    if action == "NOOP" or action == "WAIT" or action == "HOLD_POSITION"
        or action == "REST" then
        return { action = "WAIT" }
    end
    if action == "FOLLOW" or action == "FOLLOW_GOBLIN" or action == "REGROUP"
        or action == "GO_HOME" or action == "RETURN_TO_BASE" then
        local copy = { action = "FOLLOW" }
        if type(message.target) == "table"
            and string.lower(tostring(message.target.kind or "")) == "player" then
            copy.owner = message.target.player or message.target.name or message.target.label
        end
        return copy
    end
    if movementActions[action] then
        -- Qwen can name a semantic destination but cannot provide world
        -- coordinates.  The safe deterministic fallback is to regroup with
        -- the owner; exact MOVE_TO is reserved for the developer command.
        return { action = "FOLLOW" }
    end
    return nil
end

local function process(stem)
    local message = IPC.readReady("commands", stem)
    if message == nil or message.type ~= "command.npc_action" then
        IPC.deadletter("commands", stem, "malformed Goblin command")
        return
    end
    if not remember(message.request_id) then
        IPC.archive("commands", stem, "duplicate Goblin request")
        return
    end
    if not Config.enabled or not valid(message) then
        log("COMMAND_REJECTED id=" .. tostring(message.request_id))
        IPC.writeResponse(message.request_id, "rejected", "Goblin command failed server validation")
        IPC.acknowledge(message.request_id, "rejected")
        IPC.archive("commands", stem, "Goblin command rejected")
        return
    end
    local body = Spawner.ensure(false)
    local command = normalizedMessage(message)
    local accepted, detail = false, "unsupported Goblin command"
    if body ~= nil and command ~= nil then
        accepted, detail = Brain.execute(command, body)
    elseif body == nil then
        detail = "Goblin body is not currently present"
    end
    local status = accepted and "accepted" or "failed"
    log("QWEN_COMMAND id=" .. tostring(message.request_id)
        .. " action=" .. tostring(message.action) .. " status=" .. status)
    IPC.writeResponse(message.request_id, status, detail)
    IPC.acknowledge(message.request_id, status)
    IPC.archive("commands", stem, "Goblin command finalized: " .. status)
end

function Bridge.tick()
    if not IPC.isReady() and not IPC.initialize() then return end
    if not Config.enabled then return end
    local ready = IPC.listReady("commands")
    for index, stem in ipairs(ready) do
        if index > 32 then break end
        process(stem)
    end
end

return Bridge
