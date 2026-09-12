-- Typed Qwen/Discord bridge.  Every command resolves to one player's Goblin.
local Config = require("GoblinSurvivor/Config")
local IPC = require("GoblinSurvivor/IPC")
local Net = require("GoblinSurvivor/Net")
local Authority = require("GoblinSurvivor/Authority")
local Spawner = require("GoblinSurvivor/GoblinSpawner")
local Brain = require("GoblinSurvivor/GoblinBrain")
local Body = require("GoblinSurvivor/GoblinBody")

local Bridge = { seen = {}, order = {}, maxSeen = 2048 }

local actions = {
    ENTER_VEHICLE=true, EXIT_VEHICLE=true,
    FARM=true, CRAFT=true, REPAIR_VEHICLE=true,
    OPEN_DOOR=true, OPEN_WINDOW=true, CLOSE_CURTAINS=true,
    NOOP=true, WAIT=true, SAY=true, EQUIP=true, FOLLOW=true, FOLLOW_GOBLIN=true,
    HOLD_POSITION=true, REGROUP=true, HELP=true, SEARCH=true, SCAVENGE=true,
    LOOT=true, LOOT_AREA=true, RETURN_TO_BASE=true, GO_HOME=true, RETURN=true,
    SET_BASE=true, REMEMBER_BASE=true, SECURE_BASE=true, BUILD=true, ATTACK=true,
    DEFEND_PLAYER=true, DEFEND_AREA=true, CLEAR_BUILDING=true, REST=true,
    RETREAT=true, FLEE=true, MOVE_TO=true
}

local allowedKeys = {
    protocol=true, request_id=true, timestamp_ms=true, type=true, npc_id=true,
    owner=true, action=true, priority=true, reason=true, text=true, target=true,
    item=true, job=true, loot_focus=true, authority_token=true, controller_action=true, autonomous=true
}
local targetKeys = { kind=true, name=true, player=true, label=true }
local itemKeys = { name=true, count=true, category=true }

local function log(text)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(text)) end
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
    return safeText(target.name or target.label or target.player, 96)
end

local function validNpcId(value)
    if type(value) ~= "string" or #value > 96 then return false end
    if value == Config.npcId then return true end -- legacy envelope; owner must resolve it below.
    return string.sub(value, 1, #Config.npcId + 1) == Config.npcId .. "."
end

local function valid(message)
    if type(message) ~= "table" or not Net.safeTable(message) then return false end
    for key in pairs(message) do
        if type(key) ~= "string" or not allowedKeys[string.lower(key)] then return false end
    end
    if type(message.action) ~= "string" then return false end
    local action = string.upper(message.action)
    if action ~= message.action or not actions[action] then return false end
    if not validNpcId(message.npc_id) then return false end
    if message.owner ~= nil and not safeText(message.owner, 96) then return false end
    if message.priority ~= nil and (type(message.priority) ~= "number"
        or math.floor(message.priority) ~= message.priority or message.priority < 0
        or message.priority > 3) then return false end
    if message.reason ~= nil and not safeText(message.reason, 240) then return false end
    if message.text ~= nil and not safeText(message.text, 240) then return false end
    if action == "SAY" and message.text == nil then return false end
    if message.loot_focus ~= nil then
        local focus = string.lower(tostring(message.loot_focus))
        if focus ~= "food" and focus ~= "medical" and focus ~= "tools"
            and focus ~= "ammo" and focus ~= "surprise" then return false end
    end
    if message.job~=nil and not safeText(message.job,32) then return false end
    if message.target ~= nil and not validTarget(message.target) then return false end
    if message.item ~= nil then
        if type(message.item) ~= "table" then return false end
        for key in pairs(message.item) do
            if type(key) ~= "string" or not itemKeys[string.lower(key)] then return false end
        end
        if not safeText(message.item.name, 96) then return false end
        local count=message.item.count
        if count~=nil and (type(count)~="number" or count~=math.floor(count) or count<1 or count>10) then return false end
    end
    if action == "EQUIP" and (type(message.item) ~= "table"
        or message.item.name ~= Config.weaponType) then return false end
    if message.authority_token ~= nil and not Net.safeId(message.authority_token, 128) then return false end
    if message.controller_action ~= nil and not Net.safeTable(message.controller_action) then return false end
    if message.autonomous ~= nil and type(message.autonomous) ~= "boolean" then return false end
    if message.autonomous ~= true and Authority.requires(action) and not Authority.consume(message) then return false end
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

local function resolveBody(message)
    local body = Spawner.findByNpcId(message.npc_id)
    if body ~= nil then
        if type(message.owner) ~= "string" or string.lower(message.owner) ~= string.lower(Body.owner(body) or "") then return nil end
        return body
    end
    if message.npc_id == Config.npcId and type(message.owner) == "string" then
        return Spawner.findForOwner(message.owner)
    end
    return nil
end

local function normalizedMessage(message)
    local action = string.upper(message.action)
    if action == "SEARCH" or action == "SCAVENGE" or action == "LOOT_AREA" then
        return { action = "LOOT", loot_focus = message.loot_focus or "surprise" }
    end
    if action == "NOOP" or action == "WAIT" or action == "HOLD_POSITION" or action == "REST" then
        return { action = "WAIT" }
    end
    if action == "FOLLOW_GOBLIN" or action == "REGROUP" or action == "HELP" then
        return { action = "FOLLOW" }
    end
    if action == "GO_HOME" or action == "RETURN" then
        return { action = "RETURN_TO_BASE" }
    end
    if action == "REMEMBER_BASE" then
        return { action = "SET_BASE" }
    end
    if action == "DEFEND_PLAYER" or action == "DEFEND_AREA" or action == "CLEAR_BUILDING" then
        return { action = "ATTACK" }
    end
    if action == "RETREAT" or action == "FLEE" then
        return { action = "FOLLOW" }
    end
    return message
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
        IPC.writeResponse(message.request_id, "rejected", "Goblin command failed server validation")
        IPC.acknowledge(message.request_id, "rejected")
        IPC.archive("commands", stem, "Goblin command rejected")
        return
    end

    local body = resolveBody(message)
    local accepted, detail = false, "requested player's Goblin is not present"
    if body ~= nil then
        if message.autonomous == true then
            if Authority.consumeOffline(message, body) then
                local normalized = normalizedMessage(message)
                normalized.autonomous = true
                accepted, detail = Brain.execute(normalized, body)
            else
                detail = "offline grant expired, owner returned, or task changed"
            end
        else
            accepted, detail = Brain.execute(normalizedMessage(message), body)
        end
    end
    local status = accepted and "accepted" or "failed"
    if body and not accepted and message.action~="SAY" then
        Body.say(body,"Comrade, "..tostring(detail)..".")
    end
    log("QWEN_COMMAND request=" .. tostring(message.request_id)
        .. " npc_id=" .. tostring(message.npc_id)
        .. " owner=" .. tostring(message.owner or (body ~= nil and require("GoblinSurvivor/GoblinBody").owner(body)))
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
