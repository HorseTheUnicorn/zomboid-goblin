local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Net = require("GoblinSurvivor/Net")
local Telemetry = require("GoblinSurvivor/Telemetry")
local Authority = require("GoblinSurvivor/Authority")
local ClientSurvivorServer = require("GoblinSurvivor/ClientSurvivorServer")

local CommandLoop = {
    seen = {}, seenOrder = {}, maxSeen = 2048,
    pending = {}, pendingTimeoutMs = 120000
}

local LegacyModules
local function legacyModules()
    if LegacyModules == nil then
        LegacyModules = {
            GoblinNPC = require("GoblinSurvivor/GoblinNPC"),
            ActionExecutor = require("GoblinSurvivor/ActionExecutor")
        }
    end
    return LegacyModules
end

local actions = {
    NOOP = true, DEBUG_KILL = true, DEBUG_SPAWN_ZOMBIE = true, SAY = true, MOVE_TO = true, FOLLOW = true, FOLLOW_GOBLIN = true,
    HOLD_POSITION = true, REGROUP = true, SEARCH = true, SCAVENGE = true,
    LOOT_AREA = true, RETREAT = true, FLEE = true, REST = true, GO_HOME = true,
    ATTACK = true, MELEE_ATTACK = true, DEFEND_PLAYER = true, DEFEND_AREA = true, GUARD = true,
    PATROL = true, RETURN_TO_BASE = true, CLEAR_BUILDING = true,
    JOIN_PARTY = true, LEAVE_PARTY = true, FORM_SQUAD = true, DISMISS_SQUAD = true,
    ASSIGN_JOB = true, SET_MOVEMENT = true, SET_VEHICLE_RECOVERY = true,
    SECURE_BASE = true, ENTER_VEHICLE = true, EXIT_VEHICLE = true,
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
    movement_mode = true, enabled = true,
    authority_token = true, observe_only = true, source = true
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
    if message.observe_only ~= nil and type(message.observe_only) ~= "boolean" then
        return false
    end
    if message.enabled ~= nil and type(message.enabled) ~= "boolean" then
        return false
    end
    if message.action == "SET_VEHICLE_RECOVERY" and message.enabled == nil then
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

local immediateActions = {
    NOOP = true, SAY = true, HOLD = true, HOLD_POSITION = true,
    REST = true, SET_MOVEMENT = true, SET_VEHICLE_RECOVERY = true,
    FORM_SQUAD = true, DISMISS_SQUAD = true, ASSIGN_JOB = true
}

local function terminalResult(requestId, status, detail)
    IPC.writeResponse(requestId, status, detail)
    IPC.acknowledge(requestId, status, detail, true)
end

local function updatePending()
    local now = os.time() * 1000
    local statusFn = ClientSurvivorServer.commandStatus
    for requestId, pending in pairs(CommandLoop.pending) do
        local status, detail = "RUNNING", "survivor task remains active"
        if type(statusFn) == "function" then
            local ok, result, resultDetail = pcall(
                statusFn, pending.actor_id, pending.action
            )
            if ok and type(result) == "string" then
                status = result
                detail = resultDetail or detail
            end
        end
        if status == "SUCCESS" or status == "FAILED" then
            terminalResult(requestId, status, detail)
            CommandLoop.pending[requestId] = nil
        elseif now >= pending.deadline_ms then
            terminalResult(requestId, "TIMEOUT", "survivor task exceeded its bounded execution window")
            CommandLoop.pending[requestId] = nil
        end
    end
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
        terminalResult(message.request_id, "REJECTED", "GoblinEnabled=false")
        IPC.deadletter("commands", stem, "GoblinEnabled=false")
        return
    end
    -- Storm performs the second semantic admission check before Lua resolves
    -- the command to a native body.  Keep the Lua validator below as the
    -- final wire/schema gate and as the compatibility path when Storm is not
    -- loaded in a legacy development profile.
    local javaValidate = rawget(_G, "validateGoblinSurvivorCommand")
    if type(javaValidate) == "function" then
        local ok, valid = pcall(javaValidate, message)
        if not ok or valid ~= true then
            terminalResult(message.request_id, "REJECTED", "Storm rejected the semantic NPC command")
            IPC.archive("commands", stem, "Storm semantic command rejection")
            return
        end
    end
    local normalize = rawget(_G, "normalizeGoblinAction")
    if type(normalize) == "function" and type(message.action) == "string" then
        local ok, normalized = pcall(normalize, message.action)
        if ok and type(normalized) == "string" and #normalized > 0 then
            message.action = normalized
        end
    end
    if not validAction(message) then
        terminalResult(message.request_id, "REJECTED", "NPC action failed server-side validation")
        IPC.archive("commands", stem, "NPC action rejected")
        return
    end
    IPC.acknowledge(
        message.request_id, "ACCEPTED", "semantic command admitted", false
    )
    local accepted, detail
    if Config.bodyMode == "client_survivor" then
        accepted, detail = ClientSurvivorServer.execute(message)
    else
        local legacy = legacyModules()
        local zombie = legacy.GoblinNPC.findGoblin()
        accepted, detail = legacy.ActionExecutor.execute(message, zombie)
    end
    if not accepted then
        terminalResult(message.request_id, "FAILED", detail)
        IPC.archive("commands", stem, "NPC action finalized: FAILED")
        return
    end
    if immediateActions[message.action] then
        terminalResult(message.request_id, "SUCCESS", detail)
    else
        IPC.acknowledge(message.request_id, "RUNNING", detail, false)
        CommandLoop.pending[message.request_id] = {
            actor_id = message.npc_id,
            action = message.action,
            deadline_ms = os.time() * 1000 + CommandLoop.pendingTimeoutMs
        }
    end
    IPC.archive("commands", stem, "NPC action admitted: " .. tostring(message.action))
end

function CommandLoop.tick()
    if not IPC.isReady() or not Config.enabled then return end
    if Config.bodyMode ~= "client_survivor" then
        legacyModules().GoblinNPC.ensure()
    end
    Telemetry.writeExactState()
    updatePending()
    local ready = IPC.listReady("commands")
    local processed = 0
    for _, stem in ipairs(ready) do
        if processed >= 32 then break end
        process(stem)
        processed = processed + 1
    end
end

return CommandLoop
