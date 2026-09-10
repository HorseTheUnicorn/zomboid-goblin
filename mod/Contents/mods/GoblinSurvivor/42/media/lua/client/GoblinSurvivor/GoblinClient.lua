-- Client-side presentation and chat relay for every managed Goblin.
--
-- The server owns spawning/tasks. This file keeps the replicated IsoZombie
-- friendly and applies one deterministic custom full-body outfit. Visual
-- success is verified from PZ's ItemVisual/ClothingItem state; a Java method
-- merely returning without throwing is not treated as proof that it rendered.
local Config = require("GoblinSurvivor/Config")
local EventHooks = require("GoblinSurvivor/EventHooks")

local VISUAL_GUID = "6bd4b657-5e6c-4b17-9b53-3f6bb6d4f3d1"
local VISUAL_OUTFIT = "GoblinCompanion"

local Client = {
    statesById = {},
    statesByOnline = {},
    lastRequestAt = 0,
    lastScanAt = 0,
    visualReady = setmetatable({}, { __mode = "k" }),
    visualPrepared = setmetatable({}, { __mode = "k" }),
    nextVisualAttemptAt = setmetatable({}, { __mode = "k" }),
    clothingDiagnosticDone = false
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

local function clearItemVisuals(zombie)
    call(zombie, "clearWornItems")
    local okVisuals, visuals = call(zombie, "getItemVisuals")
    if okVisuals and visuals ~= nil then call(visuals, "clear") end
end

local function readField(object, field)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[field] end)
    return ok and value or nil
end

local function clothingAssetInfo()
    local managerClass = rawget(_G, "OutfitManager")
    local manager = managerClass ~= nil and readField(managerClass, "instance") or nil
    if manager == nil then
        return nil, "OutfitManager.instance unavailable"
    end

    local okItem, clothing = call(manager, "getClothingItem", VISUAL_GUID)
    if not okItem or clothing == nil then
        return nil, "GUID not registered"
    end

    local _, hasModel = call(clothing, "hasModel")
    local _, maleModel = call(clothing, "getModel", false)
    local _, femaleModel = call(clothing, "getModel", true)
    local _, texture = call(clothing, "GetATexture")
    local guid = readField(clothing, "guid")
    return clothing,
        "guid=" .. tostring(guid)
        .. " has_model=" .. tostring(hasModel)
        .. " male_model=" .. tostring(maleModel)
        .. " female_model=" .. tostring(femaleModel)
        .. " texture=" .. tostring(texture)
end

local function diagnoseClothingAsset()
    if Client.clothingDiagnosticDone then return end
    Client.clothingDiagnosticDone = true
    local clothing, detail = clothingAssetInfo()
    if clothing == nil then
        log("CLIENT_CLOTHING_UNRESOLVED guid=" .. VISUAL_GUID .. " detail=" .. tostring(detail))
    else
        log("CLIENT_CLOTHING_RESOLVED " .. tostring(detail))
    end
end

local function visualContainsGoblin(zombie)
    local okVisuals, visuals = call(zombie, "getItemVisuals")
    if not okVisuals or visuals == nil then return false, "ItemVisuals unavailable" end
    local okSize, size = call(visuals, "size")
    size = okSize and tonumber(size) or 0

    for index = 0, size - 1 do
        local okVisual, visual = call(visuals, "get", index)
        if okVisual and visual ~= nil then
            local _, clothing = call(visual, "getClothingItem")
            local _, clothingName = call(visual, "getClothingItemName")
            local _, itemType = call(visual, "getItemType")
            if clothing ~= nil then
                local guid = readField(clothing, "guid")
                local _, model = call(clothing, "getModel", false)
                local _, texture = call(clothing, "GetATexture")
                if guid == VISUAL_GUID or model == Config.npcVisualAsset then
                    return true,
                        "index=" .. tostring(index)
                        .. " clothing=" .. tostring(clothingName)
                        .. " item_type=" .. tostring(itemType)
                        .. " model=" .. tostring(model)
                        .. " texture=" .. tostring(texture)
                end
            end
            if clothingName == "Goblin_MysteryBody" then
                return true, "index=" .. tostring(index) .. " clothing=Goblin_MysteryBody"
            end
        end
    end
    return false, "Goblin ItemVisual absent count=" .. tostring(size)
end

local function ensureVisual(zombie, state)
    if Client.visualReady[zombie] == true then return true end
    local timestamp = nowMs()
    if timestamp > 0 and timestamp < (Client.nextVisualAttemptAt[zombie] or 0) then return false end
    Client.nextVisualAttemptAt[zombie] = timestamp + 2000

    diagnoseClothingAsset()

    if Client.visualPrepared[zombie] ~= true then
        call(zombie, "setDressInRandomOutfit", false)
        call(zombie, "setAsSurvivor")
        call(zombie, "setDressInRandomOutfit", false)
        call(zombie, "setFemaleEtc", false)
        call(zombie, "setSkeleton", false)
        call(zombie, "setCrawler", false)
        clearItemVisuals(zombie)
        Client.visualPrepared[zombie] = true
    end

    -- Prefer a named outfit. PZ's native outfit pipeline resolves the GUID and
    -- creates the ItemVisual exactly as it does for ordinary deterministic
    -- zombie outfits. GoblinCompanion contains only the Goblin body item.
    call(zombie, "dressInNamedOutfit", VISUAL_OUTFIT)
    call(zombie, "onWornItemsChanged")
    local present, detail = visualContainsGoblin(zombie)

    -- Keep the direct-GUID API as a bounded fallback, but verify the resulting
    -- ItemVisual instead of trusting the void Java method call itself.
    if not present then
        call(zombie, "dressInClothingItem", VISUAL_GUID)
        call(zombie, "onWornItemsChanged")
        present, detail = visualContainsGoblin(zombie)
    end

    call(zombie, "resetModel")
    call(zombie, "resetModelNextFrame")

    if not present then
        log("CLIENT_VISUAL_FAILED npc_id=" .. tostring(state.npc_id)
            .. " outfit=" .. VISUAL_OUTFIT
            .. " detail=" .. tostring(detail))
        return false
    end

    Client.visualReady[zombie] = true
    log("CLIENT_VISUAL_CONFIRMED npc_id=" .. tostring(state.npc_id)
        .. " asset=" .. tostring(Config.npcVisualAsset)
        .. " detail=" .. tostring(detail))
    return true
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
        local sent = send("debug", { text = "/goblin " .. command })
        log("CHAT_RELAY kind=debug speaker=" .. tostring(localName) .. " sent=" .. tostring(sent))
        return
    end
    if string.find(lower, "goblin", 1, true) ~= nil then
        local sent = send("chat", {
            text = text,
            tab_id = type(tabId) == "number" and tabId or 0
        })
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
    .. " visual_outfit=" .. VISUAL_OUTFIT
    .. " visual_guid=" .. VISUAL_GUID)
requestState()
return Client
