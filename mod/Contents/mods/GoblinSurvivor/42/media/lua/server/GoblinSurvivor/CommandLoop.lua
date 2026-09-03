local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local CharacterController = require("GoblinSurvivor/CharacterController")
local ClientBridge = require("GoblinSurvivor/ClientBridge")

local CommandLoop = {
    seen = {},
    seenOrder = {},
    maxSeen = 2048
}

local intents = {
    WAIT = true,
    SAY = true,
    MOVE_TO = true,
    FOLLOW = true,
    SEARCH = true,
    SCAVENGE = true,
    RETREAT = true,
    REST = true,
    GO_HOME = true,
    JOIN_PARTY = true,
    LEAVE_PARTY = true,
    HUNT_START = true,
    HUNT_HINT = true,
    HUNT_RELOCATE = true,
    HUNT_REWARD = true,
    TRADE = true,
    HELP = true
}

local modes = {
    SAFE = true,
    ROAM = true,
    PARTY = true,
    HUNT = true
}

local targetKinds = {
    nearby_building = true,
    named_location = true,
    area = true,
    player = true,
    home_base = true,
    escape_route = true,
    candidate = true,
    current_position = true
}

local allowedKeys = {
    intent = true,
    mode = true,
    text = true,
    priority = true,
    abort_if = true,
    target = true,
    item = true,
    candidate = true,
    loot_focus = true,
    controller_action = true
}

local forbiddenKeys = {
    code = true,
    command = true,
    eval = true,
    exec = true,
    lua = true,
    shell = true,
    script = true,
    raw = true,
    raw_packet = true,
    packet = true,
    x = true,
    y = true,
    z = true,
    cell = true,
    chunk = true,
    building_id = true,
    teleport = true
}

local function textIsSafe(value, maximum)
    if type(value) ~= "string" or #value == 0 or #value > maximum then
        return false
    end
    for index = 1, #value do
        local byte = string.byte(value, index)
        if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
            return false
        end
    end
    local lower = string.lower(value)
    if string.find(lower, "coordinates")
        or string.find(lower, "x%s*=")
        or string.find(lower, "y%s*=")
        or string.find(lower, "z%s*=")
        or string.find(lower, "cell%s*=")
        or string.find(lower, "chunk%s*=") then
        return false
    end
    return true
end

local function safeTable(value, depth)
    if type(value) ~= "table" then
        return true
    end
    if depth > 3 then
        return false
    end
    for key, nested in pairs(value) do
        if type(key) ~= "string" then
            return false
        end
        local normalized = string.lower(key)
        if forbiddenKeys[normalized] then
            return false
        end
        if not safeTable(nested, depth + 1) then
            return false
        end
    end
    return true
end

local function validTarget(value)
    if type(value) ~= "table" then
        return false
    end
    local kind = value.kind
    if type(kind) ~= "string" or not targetKinds[string.lower(kind)] then
        return false
    end
    local label = value.name or value.label or value.player
    return textIsSafe(label, 96)
end

local function validIntent(message)
    if type(message) ~= "table" or not safeTable(message, 0) then
        return false
    end
    local intent = message.intent
    local mode = message.mode
    if type(intent) ~= "string" or not intents[string.upper(intent)] then
        return false
    end
    if type(mode) ~= "string" or not modes[string.upper(mode)] then
        return false
    end
    for key, _ in pairs(message) do
        if type(key) ~= "string" or not allowedKeys[string.lower(key)] then
            if key ~= "protocol" and key ~= "request_id" and key ~= "timestamp_ms" and key ~= "type" then
                return false
            end
        end
    end
    if message.text ~= nil and not textIsSafe(message.text, 240) then
        return false
    end
    if message.priority ~= nil and (type(message.priority) ~= "number" or message.priority < 0 or message.priority > 3) then
        return false
    end
    if message.target ~= nil and not validTarget(message.target) then
        return false
    end
    if message.candidate ~= nil and not validTarget(message.candidate) then
        return false
    end
    if string.upper(intent) == "SAY" and not message.text then
        return false
    end
    if string.upper(intent) == "HUNT_RELOCATE" and not message.candidate then
        return false
    end
    if message.controller_action ~= nil then
        if type(message.controller_action) ~= "table"
            or not safeTable(message.controller_action, 0) then
            return false
        end
        local actionKeys = {
            action = true,
            priority = true,
            reason = true,
            target = true,
            item = true
        }
        local action = message.controller_action
        for key, _ in pairs(action) do
            if type(key) ~= "string" or not actionKeys[string.lower(key)] then
                return false
            end
        end
        if type(action.action) ~= "string"
            or not string.find(action.action, "^[A-Z_]+$")
            or not ({
                NOOP = true,
                SAY = true,
                MOVE_TO = true,
                FOLLOW = true,
                SEARCH = true,
                SCAVENGE = true,
                RETREAT = true,
                REST = true,
                GO_HOME = true,
                JOIN_PARTY = true,
                LEAVE_PARTY = true,
                ATTACK = true,
                FLEE = true,
                EAT = true,
                DRINK = true,
                BANDAGE = true,
                RELOAD = true,
                CLAIM_REWARD = true
            })[action.action] then
            return false
        end
        if action.priority ~= nil
            and (type(action.priority) ~= "number" or action.priority < 0 or action.priority > 3) then
            return false
        end
        if action.reason ~= nil and not textIsSafe(action.reason, 240) then
            return false
        end
        if action.target ~= nil and not validTarget(action.target) then
            return false
        end
        if action.item ~= nil then
            if type(action.item) ~= "table"
                or not textIsSafe(action.item.name, 96)
                or type(action.item.count) ~= "number"
                or math.floor(action.item.count) ~= action.item.count
                or action.item.count < 1
                or action.item.count > 10 then
                return false
            end
        end
    end
    return true
end

local function validCharacterCommand(message)
    if type(message) ~= "table" or not safeTable(message, 0) then
        return false
    end
    for key, _ in pairs(message) do
        if key ~= "protocol" and key ~= "request_id" and key ~= "timestamp_ms"
            and key ~= "type" and key ~= "generation"
            and key ~= "catalog_version" and key ~= "proposal" then
            return false
        end
    end
    if type(message.generation) ~= "number" or message.generation < 1
        or math.floor(message.generation) ~= message.generation
        or type(message.catalog_version) ~= "string"
        or #message.catalog_version == 0 or #message.catalog_version > 64
        or type(message.proposal) ~= "table" then
        return false
    end
    return true
end

local function validRecreationCommand(message)
    if type(message) ~= "table" or not safeTable(message, 0)
        or type(message.request_id) ~= "string"
        or not Net.safeId(message.request_id, 128) then
        return false
    end
    for key, _ in pairs(message) do
        if key ~= "protocol" and key ~= "request_id"
            and key ~= "timestamp_ms" and key ~= "type"
            and key ~= "generation" then
            return false
        end
    end
    if message.generation ~= nil
        and (type(message.generation) ~= "number"
            or math.floor(message.generation) ~= message.generation
            or message.generation < 1
            or message.generation > 2147483647) then
        return false
    end
    return true
end

local function remember(requestId)
    if CommandLoop.seen[requestId] then
        return false
    end
    CommandLoop.seen[requestId] = true
    table.insert(CommandLoop.seenOrder, requestId)
    if #CommandLoop.seenOrder > CommandLoop.maxSeen then
        local old = table.remove(CommandLoop.seenOrder, 1)
        CommandLoop.seen[old] = nil
    end
    return true
end

local function process(stem)
    local message = IPC.readReady("commands", stem)
    if not message then
        IPC.deadletter("commands", stem, "malformed or unreadable command")
        return
    end
    if message.type ~= "command.intent"
        and message.type ~= "command.character_create"
        and message.type ~= "command.character_recreate" then
        IPC.deadletter("commands", stem, "unexpected command type")
        return
    end
    if not remember(message.request_id) then
        IPC.archive("commands", stem, "duplicate request id")
        return
    end
    if not Config.enabled then
        IPC.deadletter("commands", stem, "GoblinEnabled=false")
        return
    end
    if message.type == "command.character_create" then
        if not validCharacterCommand(message) then
            IPC.deadletter("commands", stem, "character command failed PZ-side validation")
            return
        end
        local accepted, detail = CharacterController.apply(message)
        local status = accepted and "accepted" or "rejected"
        IPC.writeResponse(message.request_id, status, detail)
        IPC.acknowledge(message.request_id, status)
        IPC.archive("commands", stem, "character command finalized: " .. status)
        return
    end
    if message.type == "command.character_recreate" then
        if not validRecreationCommand(message) then
            IPC.deadletter("commands", stem, "recreation command failed PZ-side validation")
            return
        end
        local accepted, detail = ClientBridge.requestRecreation(message)
        local status = accepted and "accepted" or "rejected"
        IPC.writeResponse(message.request_id, status, detail)
        IPC.acknowledge(message.request_id, status)
        IPC.archive("commands", stem, "recreation command finalized: " .. status)
        return
    end
    if not validIntent(message) then
        IPC.deadletter("commands", stem, "intent failed PZ-side validation")
        return
    end
    local accepted, detail = ClientBridge.sendIntent(message)
    local status = accepted and "accepted" or "rejected"
    IPC.writeResponse(message.request_id, status, detail)
    IPC.acknowledge(message.request_id, status)
    IPC.archive("commands", stem, "typed action finalized: " .. status)
end

function CommandLoop.tick()
    if not Config.enabled then
        return
    end
    local stems = IPC.listReady("commands")
    local limit = 8
    for index, stem in ipairs(stems) do
        if index > limit then
            break
        end
        process(stem)
    end
end

return CommandLoop
