-- Replicated Goblin appearance, simulation-owner movement and chat relay.
local Config = require("GoblinSurvivor/Config")
local EventHooks = require("GoblinSurvivor/EventHooks")
local Appearance = require("GoblinSurvivor/GoblinAppearance")
local Motion = require("GoblinSurvivor/GoblinLocomotion")

local Client = {
    statesById = {},
    statesByOnline = {},
    lastRequestAt = 0,
    lastScanAt = 0,
    nextFollowAt = setmetatable({}, { __mode = "k" })
}

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first, second = pcall(member, object, ...)
    return ok, first, second
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return 0
end

local function log(text)
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(text)) end
end

local function onlineId(zombie)
    local ok, value = call(zombie, "getOnlineID")
    return ok and type(value) == "number" and value >= 0 and value or nil
end

local function dataFor(zombie)
    local ok, data = call(zombie, "getModData")
    return ok and data or nil
end

local function requestState()
    local modData = rawget(_G, "ModData")
    if modData == nil or type(modData.request) ~= "function" then return false end
    local ok = pcall(modData.request, "GoblinCompanions")
    if ok then Client.lastRequestAt = nowMs() end
    return ok
end

local function rebuildState(data)
    Client.statesById = {}
    Client.statesByOnline = {}
    local companions = type(data) == "table" and data.companions or nil
    if type(companions) ~= "table" then return end
    for _, state in ipairs(companions) do
        if type(state) == "table" and type(state.npc_id) == "string" then
            Client.statesById[state.npc_id] = state
            if type(state.online_id) == "number" and state.online_id >= 0 then Client.statesByOnline[state.online_id] = state end
        end
    end
end

local function stateFor(zombie)
    local data = dataFor(zombie)
    if data ~= nil and data.GoblinNPC == true and type(data.GoblinID) == "string" then
        return Client.statesById[data.GoblinID] or {
            npc_id = data.GoblinID,
            owner = data.GoblinOwner,
            body_present = true,
            task = data.GoblinTask,
            physical_state = data.GoblinPhysicalState,
            move_type = data.GoblinMoveType,
            combat_state = data.GoblinCombatState
        }
    end
    local id = onlineId(zombie)
    return id ~= nil and Client.statesByOnline[id] or nil
end

local function position(object)
    local okX, x = call(object, "getX")
    local okY, y = call(object, "getY")
    local okZ, z = call(object, "getZ")
    if not okX or not okY or not okZ then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

local function dist2(a, b)
    if a == nil or b == nil or a.x == nil or b.x == nil then return math.huge end
    return (a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2
end

local function players()
    local result = {}
    if type(getOnlinePlayers) == "function" then
        local ok, list = pcall(getOnlinePlayers)
        if ok and list ~= nil then
            local okSize, size = call(list, "size")
            size = okSize and tonumber(size) or 0
            for i = 0, size - 1 do
                local okPlayer, player = call(list, "get", i)
                if okPlayer and player ~= nil then result[#result + 1] = player end
            end
        end
    end
    if #result == 0 and type(getPlayer) == "function" then
        local ok, player = pcall(getPlayer)
        if ok and player ~= nil then result[1] = player end
    end
    return result
end

local function playerForOwner(owner)
    local wanted = string.lower(tostring(owner or ""))
    for _, player in ipairs(players()) do
        local okName, name = call(player, "getUsername")
        if okName and type(name) == "string" and string.lower(name) == wanted then return player end
    end
    return nil
end

local function clearZombieAI(zombie)
    call(zombie, "setTarget", nil)
    call(zombie, "setThumpTarget", nil)
    call(zombie, "setAttackTargetSquare", nil)
    call(zombie, "setEatBodyTarget", nil, false)
    call(zombie, "clearAggroList")
    call(zombie, "setNoTeeth", true)
    call(zombie, "setCanWalk", true)
    call(zombie, "setCrawler", false)
    call(zombie, "setFakeDead", false)
    call(zombie, "setSkeleton", false)
    call(zombie, "setZombiesDontAttack", true)
    call(zombie, "setDressInRandomOutfit", false)
    call(zombie, "setSpeedMod", 1.0)
    call(zombie, "setVoiceSoundName", "")
    call(zombie, "setBiteSoundName", "")
end

local function followAssist(zombie, state)
    if not Motion.controls(zombie) then
        Motion.paths[zombie] = nil
        return
    end
    if state.owner_online == false then Motion.stop(zombie) return end
    local goal, gap = state.movement_goal, nil
    if state.task == "FOLLOW" then
        local owner = playerForOwner(state.owner)
        if owner ~= nil then goal, gap = Motion.followGoal(zombie, owner) else goal = nil end
    elseif state.task ~= "MOVE_TO" and state.task ~= "RETURN_TO_BASE" then
        goal = nil
    end
    local move = goal and ((gap or 0) >= Config.followRunDistance and "RUN" or "WALK") or "IDLE"
    Motion.drive(zombie, goal, move, nowMs())
end

local function apply(zombie)
    local state = stateFor(zombie)
    if state == nil or state.body_present == false then return false end
    clearZombieAI(zombie)
    local moveType = state.move_type or "IDLE"
    local physical = state.physical_state or "IDLE"
    local combat = state.combat_state or "NONE"
    local moving = moveType ~= "IDLE"
    local running = moveType == "RUN"
    local attacking = physical == "ATTACKING" or combat == "ATTACKING"

    call(zombie, "setVariable", "GoblinNPC", true)
    call(zombie, "setVariable", "GoblinID", state.npc_id)
    call(zombie, "setVariable", "GoblinHumanized", true)
    call(zombie, "setVariable", "GoblinTask", state.task or "FOLLOW")
    call(zombie, "setVariable", "GoblinMoveType", moveType)
    call(zombie, "setVariable", "GoblinPhysicalState", physical)
    call(zombie, "setVariable", "GoblinCombatState", combat)
    call(zombie, "setVariable", "NoLungeTarget", true)
    call(zombie, "setVariable", "NoLungeAttack", true)
    call(zombie, "setVariable", "ZombieHitReaction", "Chainsaw")
    call(zombie, "setVariable", "isAttacking", attacking)
    call(zombie, "setVariable", "isMelee", false)
    call(zombie, "setRunning", running)
    call(zombie, "setSprinting", false)
    call(zombie, "setWalkType", running and "sprint" or "Walk")
    call(zombie, "setSpeedTypeFromWalkType")
    Appearance.apply(zombie, nowMs())
    followAssist(zombie, state)
    return true
end

local function scanZombies()
    if type(getCell) ~= "function" then return end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil then return end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or 0
    for i = 0, size - 1 do
        local okZombie, zombie = call(list, "get", i)
        if okZombie and zombie ~= nil then apply(zombie) end
    end
end

local function onReceiveGlobalModData(key, data)
    if key ~= "GoblinCompanions" or data == nil then return end
    rebuildState(data)
    scanZombies()
end

local function localUsername()
    if type(getPlayer) ~= "function" then return nil end
    local ok, player = pcall(getPlayer)
    if not ok or player == nil then return nil end
    local okName, name = call(player, "getUsername")
    return okName and type(name) == "string" and name or nil
end

local function send(command, args)
    if type(sendClientCommand) ~= "function" then return false end
    return pcall(sendClientCommand, "GoblinSurvivor", command, args or {})
end

local function cleanText(value)
    if type(value) ~= "string" or #value < 1 or #value > 240 then return nil end
    if string.find(value, "[%c]", 1) ~= nil then return nil end
    return value
end

local function onMessage(message, tabId)
    if message == nil then return end
    local okAuthor, author = pcall(function() return message:getAuthor() end)
    local okText, text = pcall(function() return message:getText() end)
    if not okAuthor or not okText then return end
    local localName = localUsername()
    text = cleanText(text)
    if localName == nil or text == nil or string.lower(tostring(author)) ~= string.lower(localName) then return end
    local lower = string.lower(text)
    local command = string.match(lower, "^%s*[/!]goblin%s*(.*)$")
    if command ~= nil then
        local sent = send("debug", { text = "/goblin " .. command })
        log("CHAT_RELAY kind=debug speaker=" .. tostring(localName) .. " sent=" .. tostring(sent))
        return
    end
    if string.find(lower, "goblin", 1, true) ~= nil then
        local sent = send("chat", { text = text, tab_id = type(tabId) == "number" and tabId or 0 })
        log("CHAT_RELAY kind=natural speaker=" .. tostring(localName) .. " sent=" .. tostring(sent))
    end
end

local function onTick()
    local timestamp = nowMs()
    if timestamp - Client.lastScanAt >= 1000 then
        Client.lastScanAt = timestamp
        scanZombies()
    end
    if timestamp - Client.lastRequestAt >= 5000 then requestState() end
end

local chatHook = false
if Events ~= nil then
    EventHooks.install("client.global_data_init", Events.OnInitGlobalModData, requestState)
    EventHooks.install("client.global_data_receive", Events.OnReceiveGlobalModData, onReceiveGlobalModData)
    EventHooks.install("client.zombie_create", Events.OnZombieCreate, apply)
    EventHooks.install("client.zombie_update", Events.OnZombieUpdate, apply)
    EventHooks.install("client.tick", Events.OnTick, onTick)
    chatHook = EventHooks.install("client.chat_message", Events.OnAddMessage, onMessage) == true
end

log("CLIENT_READY chat_hook=" .. tostring(chatHook)
    .. " visual=" .. Config.npcVisualAsset .. " custom_model=true movement=simulation-owner")
requestState()
return Client
