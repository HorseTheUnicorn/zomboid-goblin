-- Client visual/animation fence for every managed Goblin.
--
-- The server owns spawning, movement and tasks.  The client only recognizes
-- each networked Goblin, suppresses vanilla zombie aggression, selects the
-- human Goblin animation variables, and keeps the registered clothing-model
-- rendered.  It never teleports or directly plays animation frames.
local Config = require("GoblinSurvivor/Config")
local EventHooks = require("GoblinSurvivor/EventHooks")

local Client = {
    statesById = {},
    statesByOnline = {},
    lastRequestAt = 0,
    lastScanAt = 0,
    lastVisualAt = setmetatable({}, { __mode = "k" })
}

local function call(object, method, ...)
    if object == nil then return false, nil end
    local okMember, member = pcall(function() return object[method] end)
    if not okMember or type(member) ~= "function" then return false, nil end
    local ok, first = pcall(member, object, ...)
    return ok, first
end

local function nowMs()
    if type(getTimestampMs) == "function" then
        local ok, value = pcall(getTimestampMs)
        if ok and type(value) == "number" then return value end
    end
    return os.time() * 1000
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

local function values(collection)
    local result = {}
    if collection == nil then return result end
    if type(collection) == "table" then
        for _, value in ipairs(collection) do result[#result + 1] = value end
        if #result > 0 then return result end
    end
    local okSize, size = call(collection, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local ok, value = call(collection, "get", index)
        if ok and value ~= nil then result[#result + 1] = value end
    end
    return result
end

local function rebuildState(data)
    Client.statesById = {}
    Client.statesByOnline = {}
    local companions = type(data) == "table" and data.companions or nil
    if type(companions) ~= "table" then return end
    for _, state in ipairs(companions) do
        if type(state) == "table" and type(state.npc_id) == "string" then
            Client.statesById[state.npc_id] = state
            if type(state.online_id) == "number" and state.online_id >= 0 then
                Client.statesByOnline[state.online_id] = state
            end
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

local function findInventoryItem(inventory, fullType)
    local okItems, items = call(inventory, "getItems")
    if not okItems or items == nil then return nil end
    local okSize, size = call(items, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local okItem, item = call(items, "get", index)
        if okItem and item ~= nil then
            local okType, value = call(item, "getFullType")
            if okType and value == fullType then return item end
        end
    end
    return nil
end

local function ensureWorn(zombie, inventory, fullType)
    local item = findInventoryItem(inventory, fullType)
    if item == nil then
        local okAdd, added = call(inventory, "AddItem", fullType)
        if okAdd then item = added end
    end
    if item == nil and type(instanceItem) == "function" then
        local okInstance, instance = pcall(instanceItem, fullType)
        if okInstance then item = instance end
    end
    if item == nil then return false end
    local okLocation, location = call(item, "getBodyLocation")
    if not okLocation or location == nil then return false end
    local okWorn, result = call(zombie, "setWornItem", location, item)
    return okWorn and result ~= false
end

local function ensureVisual(zombie, state)
    local timestamp = nowMs()
    if timestamp - (Client.lastVisualAt[zombie] or 0) < 3000 then return end
    Client.lastVisualAt[zombie] = timestamp
    call(zombie, "setAsSurvivor")
    call(zombie, "setFemaleEtc", false)
    call(zombie, "setSkeleton", false)
    local okInventory, inventory = call(zombie, "getInventory")
    if not okInventory or inventory == nil then return end

    local custom = ensureWorn(zombie, inventory, Config.npcVisualItemType)
    for _, fullType in ipairs(Config.npcOutfitItems or {}) do
        ensureWorn(zombie, inventory, fullType)
    end
    if custom then
        call(zombie, "resetModel")
        call(zombie, "resetModelNextFrame")
    else
        log("CLIENT_MODEL_MISSING npc_id=" .. tostring(state.npc_id)
            .. " item=" .. tostring(Config.npcVisualItemType))
    end
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
    call(zombie, "setUseless", false)
    call(zombie, "setSpeedMod", 1.0)
    call(zombie, "setVoiceSoundName", "")
    call(zombie, "setBiteSoundName", "")
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

    call(zombie, "setVariable", "Bandit", true)
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
    call(zombie, "setVariable", "bMoving", moving)
    call(zombie, "setVariable", "isAttacking", attacking)
    call(zombie, "setVariable", "isMelee", attacking)
    call(zombie, "setRunning", running)
    call(zombie, "setSprinting", false)
    call(zombie, "setWalkType", running and "sprint" or "Walk")
    call(zombie, "setSpeedTypeFromWalkType")

    ensureVisual(zombie, state)
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
    for index = 0, size - 1 do
        local okZombie, zombie = call(list, "get", index)
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
    local ok = pcall(sendClientCommand, "GoblinSurvivor", command, args or {})
    return ok
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
    if localName == nil or text == nil
        or string.lower(tostring(author)) ~= string.lower(localName) then return end

    local lower = string.lower(text)
    local command = string.match(lower, "^%s*[/!]goblin%s*(.*)$")
    if command ~= nil then
        send("debug", { text = "/goblin " .. command })
        return
    end
    -- Natural conversation/action requests go to Qwen whenever the player
    -- explicitly addresses Goblin by name.
    if string.find(lower, "goblin", 1, true) ~= nil then
        send("chat", {
            text = text,
            tab_id = type(tabId) == "number" and tabId or 0
        })
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

if Events ~= nil then
    EventHooks.install("client.global_data_init", Events.OnInitGlobalModData, requestState)
    EventHooks.install("client.global_data_receive", Events.OnReceiveGlobalModData, onReceiveGlobalModData)
    EventHooks.install("client.zombie_create", Events.OnZombieCreate, apply)
    EventHooks.install("client.zombie_update", Events.OnZombieUpdate, apply)
    EventHooks.install("client.tick", Events.OnTick, onTick)
    EventHooks.install("client.chat_message", Events.OnAddMessage, onMessage)
end

requestState()
return Client
