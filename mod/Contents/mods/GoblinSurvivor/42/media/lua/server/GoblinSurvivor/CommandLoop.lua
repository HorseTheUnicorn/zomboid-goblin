local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Net = require("GoblinSurvivor/Net")
local GoblinNPC = require("GoblinSurvivor/GoblinNPC")
local ActionExecutor = require("GoblinSurvivor/ActionExecutor")
local Telemetry = require("GoblinSurvivor/Telemetry")
local Authority = require("GoblinSurvivor/Authority")
local ClientSurvivorServer = require("GoblinSurvivor/ClientSurvivorServer")

local CommandLoop = { seen = {}, seenOrder = {}, maxSeen = 2048 }

local actions = {
    NOOP = true, DEBUG_KILL = true, SAY = true, MOVE_TO = true, FOLLOW = true, FOLLOW_GOBLIN = true,
    HOLD_POSITION = true, REGROUP = true, SEARCH = true, SCAVENGE = true,
    LOOT_AREA = true, RETREAT = true, FLEE = true, REST = true, GO_HOME = true,
    ATTACK = true, DEFEND_PLAYER = true, DEFEND_AREA = true, GUARD = true,
    PATROL = true, RETURN_TO_BASE = true, CLEAR_BUILDING = true,
    JOIN_PARTY = true, LEAVE_PARTY = true, FORM_SQUAD = true, DISMISS_SQUAD = true,
    ASSIGN_JOB = true, SECURE_BASE = true, ENTER_VEHICLE = true, EXIT_VEHICLE = true,
    EAT = true, DRINK = true, BANDAGE = true, RELOAD = true, CLAIM_REWARD = true
}

local movementActions = {
    MOVE_TO = true, FOLLOW = true, FOLLOW_GOBLIN = true, SEARCH = true,
    SCAVENGE = true, LOOT_AREA = true, RETREAT = true, FLEE = true,
    GO_HOME = true, REGROUP = true, DEFEND_PLAYER = true, DEFEND_AREA = true,
    GUARD = true, PATROL = true, CLEAR_BUILDING = true, RETURN_TO_BASE = true
}

local targetKinds = {
    nearby_building = true, named_location = true, area = true, player = true,
    home_base = true, escape_route = true, candidate = true, current_position = true,
    nearby_threat = true, goblin = true, squad = true, base = true, vehicle = true
}

local allowedKeys = {
    protocol = true, request_id = true, timestamp_ms = true, type = true,
    npc_id = true, action = true, priority = true, reason = true,
    controller_action = true, target = true, item = true, text = true,
    leader = true, members = true, job = true, formation = true, squad_id = true,
    authority_token = true
}

local function safeText(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum
        and string.find(value, "coordinates", 1, true) == nil
        and string.find(value, "x%s*=", 1) == nil
        and string.find(value, "y%s*=", 1) == nil
        and string.find(value, "z%s*=", 1) == nil
end

local function safeId(value)
    return type(value) == "string" and Net.safeId(value, 96)
end

local function validTarget(target)
    if type(target) ~= "table" or not targetKinds[string.lower(tostring(target.kind))] then return false end
    local label = target.name or target.label or target.player
    return safeText(label, 96)
end

local function validAction(message)
    if type(message) ~= "table" or not Net.safeTable(message) then return false end
    for key, _ in pairs(message) do
        if type(key) ~= "string" or not allowedKeys[string.lower(key)] then return false end
    end
    if not actions[message.action] then return false end
    if Config.bodyMode == "client_survivor" then
        if not ClientSurvivorServer.isKnownNpcId(message.npc_id) then return false end
    elseif message.npc_id ~= Config.npcId then
        return false
    end
    if type(message.priority) ~= "number" or math.floor(message.priority) ~= message.priority
        or message.priority < 0 or message.priority > 3 then return false end
    if message.reason ~= nil and not safeText(message.reason, 240) then return false end
    if message.text ~= nil and not safeText(message.text, 240) then return false end
    if message.action == "SAY" and message.text == nil then return false end
    if message.target ~= nil and not validTarget(message.target) then return false end
    if movementActions[message.action] and message.target == nil then return false end
    if message.leader ~= nil and not safeId(message.leader) then return false end
    if message.squad_id ~= nil and not safeId(message.squad_id) then return false end
    if message.job ~= nil and not safeText(message.job, 32) then return false end
    if message.formation ~= nil and not safeText(message.formation, 16) then return false end
    if message.members ~= nil then
        if type(message.members) ~= "table" or #message.members > 16 then return false end
        for _, member in ipairs(message.members) do if not safeId(member) then return false end end
    end
    if message.item ~= nil then
        if type(message.item) ~= "table" or not safeText(message.item.name, 64)
            or type(message.item.count) ~= "number"
            or math.floor(message.item.count) ~= message.item.count
            or message.item.count < 1 or message.item.count > 10 then return false end
    end
    if message.authority_token ~= nil and not safeId(message.authority_token) then
        return false
    end
    if Authority.requires(message.action) and not Authority.consume(message) then
        return false
    end
    return true
end

local function remember(requestId)
    if CommandLoop.seen[requestId] then return false end
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
        IPC.deadletter("commands", stem, "malformed or unreadable NPC command")
        return
    end
    if message.type ~= "command.npc_action" then
        IPC.deadletter("commands", stem, "legacy or unexpected command type")
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
    if not validAction(message) then
        IPC.writeResponse(message.request_id, "rejected", "NPC action failed server-side validation")
        IPC.acknowledge(message.request_id, "rejected")
        IPC.archive("commands", stem, "NPC action rejected")
        return
    end
    local accepted, detail
    if Config.bodyMode == "client_survivor" then
        accepted, detail = ClientSurvivorServer.execute(message)
    else
        local zombie = GoblinNPC.findGoblin()
        accepted, detail = ActionExecutor.execute(message, zombie)
    end
    local status = accepted and "accepted" or "failed"
    IPC.writeResponse(message.request_id, status, detail)
    IPC.acknowledge(message.request_id, status)
    IPC.archive("commands", stem, "NPC action finalized: " .. status)
end

function CommandLoop.tick()
    if not IPC.isReady() or not Config.enabled then return end
    if Config.bodyMode ~= "client_survivor" then
        GoblinNPC.ensure()
    end
    Telemetry.writeExactState()
    local ready = IPC.listReady("commands")
    local processed = 0
    for _, stem in ipairs(ready) do
        if processed >= 32 then break end
        process(stem)
        processed = processed + 1
    end
end

return CommandLoop
