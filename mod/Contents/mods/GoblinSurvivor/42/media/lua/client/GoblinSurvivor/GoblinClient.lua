-- Client side of the rebuilt companion.
--
-- does not depend on a zombie's square-owned ModData packet.  The
-- server publishes a bounded GlobalModData record and the client matches the
-- streamed IsoZombie by its native persistent/online identity.  This module
-- follows that pattern: it never creates a body, moves coordinates, or calls
-- PlayAnim; it only reapplies replicated state/visual variables locally.
local Config = require("GoblinSurvivor/Config")
local EventHooks = require("GoblinSurvivor/EventHooks")

local Client = {
    globalState = nil,
    globalRevision = 0,
    lastReceivedSignature = nil,
    lastLoggedGlobalIdentity = nil,
    lastScanAt = 0,
    lastInvariantAt = setmetatable({}, { __mode = "k" }),
    lastStateSignature = setmetatable({}, { __mode = "k" }),
    visualApplied = setmetatable({}, { __mode = "k" }),
    visualLastAttemptAt = setmetatable({}, { __mode = "k" }),
    -- A Kahlua Java proxy can be wrapped by a different Lua object on
    -- successive OnZombieUpdate callbacks.  Keying diagnostics by that
    -- proxy defeats deduplication, so keep the one-companion diagnostic as a
    -- scalar identity signature instead.
    lastAnimationSignature = nil,
    lastAnimationLogAt = 0,
    lastNativeActionSignature = nil
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

local function log(message)
    if type(print) == "function" then
        print("[GoblinSurvivor] " .. tostring(message))
    end
end

local function dataFor(zombie)
    local ok, data = call(zombie, "getModData")
    return ok and data or nil
end

local function numeric(value)
    local result = tonumber(value)
    return result ~= nil and result == result and result ~= math.huge and result ~= -math.huge
        and result or nil
end

local function onlineId(zombie)
    local ok, value = call(zombie, "getOnlineID")
    value = ok and numeric(value) or nil
    return value ~= nil and value >= 0 and value or nil
end

local function persistentOutfitId(zombie)
    local ok, value = call(zombie, "getPersistentOutfitID")
    return ok and numeric(value) or nil
end

local function stateFor(zombie)
    local data = dataFor(zombie)
    if data ~= nil and data.GoblinNPC == true and data.GoblinID == Config.npcId then
        return Client.globalState or data
    end
    if Client.globalState ~= nil and Client.globalState.body_present ~= false then
        return Client.globalState
    end
    return nil
end

local function isGoblin(zombie)
    if zombie == nil then return false end
    local data = dataFor(zombie)
    if data ~= nil and data.GoblinNPC == true and data.GoblinID == Config.npcId then
        return true
    end

    -- Prefer the online id when the server has one.  It is exact for the
    -- current connection and avoids claiming an ordinary population zombie.
    local state = Client.globalState
    if state == nil or state.body_present == false then return false end
    local expectedOnline = numeric(state.online_id)
    local actualOnline = onlineId(zombie)
    if expectedOnline ~= nil and actualOnline ~= nil then
        return expectedOnline == actualOnline
    end

    -- During the short interval before an online id is assigned, use the
    -- explicit persistent outfit id that the server writes after the native
    -- factory returns.  This is the restart-safe identity path used until the
    -- server has an online id.
    local expectedPersistent = numeric(state.persistent_outfit_id)
        or numeric(Config.npcOutfitId)
    local actualPersistent = persistentOutfitId(zombie)
    return expectedPersistent ~= nil and actualPersistent ~= nil
        and expectedPersistent == actualPersistent
end

local function iterateZombies(callback)
    if type(getCell) ~= "function" then return end
    local okCell, cell = pcall(getCell)
    if not okCell or cell == nil then return end
    local okList, list = call(cell, "getZombieList")
    if not okList or list == nil then return end
    local okSize, size = call(list, "size")
    size = okSize and tonumber(size) or nil
    if size == nil then return end
    for index = 0, size - 1 do
        local okZombie, zombie = call(list, "get", index)
        if okZombie and zombie ~= nil then callback(zombie) end
    end
end

local function requestGlobalState()
    local modData = rawget(_G, "ModData")
    if modData == nil then return false end
    local okRequest = pcall(function()
        if type(modData.request) == "function" then
            modData.request("GoblinCompanion")
            return true
        end
        return false
    end)
    return okRequest
end

local function stateSignature(state)
    if state == nil then return "none" end
    return table.concat({
        tostring(state.generation or 0), tostring(state.online_id or "none"),
        tostring(state.persistent_outfit_id or "none"), tostring(state.state_sequence or 0),
        tostring(state.task_sequence or 0), tostring(state.task or "FOLLOW"),
        tostring(state.physical_state or "IDLE"), tostring(state.move_type or "IDLE"),
        tostring(state.combat_state or "NONE"), tostring(state.recovery_stage or ""),
        tostring(state.visual_asset or Config.npcVisualAsset),
        tostring(state.visual_applied == true), tostring(state.outfit_items
            or table.concat(Config.npcOutfitItems or {}, ",")),
        tostring(state.weapon_type or Config.weaponType)
    }, "|")
end

local function visualSignature(state)
    if state == nil then return "none" end
    return table.concat({
        tostring(state.generation or 0), tostring(state.online_id or "none"),
        tostring(state.persistent_outfit_id or "none"),
        tostring(state.visual_asset or Config.npcVisualAsset),
        tostring(state.visual_item_type or Config.npcVisualItemType),
        tostring(state.outfit_items or table.concat(Config.npcOutfitItems or {}, ",")),
        tostring(state.visual_applied == true)
    }, "|")
end

local function findInventoryItem(inventory, fullType)
    if inventory == nil or type(fullType) ~= "string" then return nil end
    local okItems, items = call(inventory, "getItems")
    if not okItems or items == nil then return nil end
    local okSize, size = call(items, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local okItem, item = call(items, "get", index)
        if okItem and item ~= nil then
            local okType, itemType = call(item, "getFullType")
            if okType and itemType == fullType then return item end
        end
    end
    return nil
end

local function resolveWornItem(inventory, fullType)
    if inventory == nil or type(fullType) ~= "string" then
        return nil, tostring(fullType) .. ":inventory-unavailable"
    end
    local item = findInventoryItem(inventory, fullType)
    if item == nil then
        local okAdd, added = call(inventory, "AddItem", fullType)
        if okAdd then item = added end
    end
    if item == nil and type(instanceItem) == "function" then
        local okInstance, instance = pcall(instanceItem, fullType)
        if okInstance then item = instance end
    end
    if item == nil then
        return nil, tostring(fullType) .. ":not-registered"
    end
    local okLocation, location = call(item, "getBodyLocation")
    if not okLocation or location == nil then
        return nil, tostring(fullType) .. ":no-body-location"
    end
    return { fullType = fullType, item = item, location = location }
end

local function itemVisualClass()
    -- ItemVisual is a Java class exposed as a global on the client.  Keep the
    -- lookup capability-gated because a headless/server Lua state does not
    -- expose it, and indexing an absent global directly can abort the hook.
    local okGlobal, class = pcall(function() return ItemVisual end)
    if okGlobal and class ~= nil then return class end
    return rawget(_G, "ItemVisual")
end

local function newItemVisual(fullType)
    local class = itemVisualClass()
    if class == nil then return nil, "ItemVisual unavailable" end
    local visual = nil
    local okNew = pcall(function() visual = class.new() end)
    if not okNew or visual == nil then return nil, "ItemVisual.new failed" end
    local okType = pcall(function() visual:setItemType(fullType) end)
    local okName = pcall(function() visual:setClothingItemName(fullType) end)
    if not okType or not okName then return nil, "ItemVisual setters failed" end
    return visual
end

local function visualMatches(visual, fullType)
    if visual == nil or type(fullType) ~= "string" then return false end
    local okType, itemType = call(visual, "getItemType")
    if okType and itemType == fullType then return true end
    local okName, clothingName = call(visual, "getClothingItemName")
    return okName and clothingName == fullType
end

local function visualsContain(visuals, fullType)
    if visuals == nil then return false end
    local okSize, size = call(visuals, "size")
    size = okSize and tonumber(size) or nil
    if size == nil then return false end
    for index = 0, size - 1 do
        local okVisual, visual = call(visuals, "get", index)
        if okVisual and visualMatches(visual, fullType) then return true end
    end
    return false
end

local function hasExpectedVisuals(zombie)
    local okVisuals, visuals = call(zombie, "getItemVisuals")
    if not okVisuals or visuals == nil then return false end
    local visualType = Config.npcVisualItemType
    if type(visualType) == "string" and visualType ~= ""
        and not visualsContain(visuals, visualType) then
        return false
    end
    local requested = Config.npcOutfitItems
    if type(requested) ~= "table" then return true end
    for index = 1, #requested do
        if not visualsContain(visuals, requested[index]) then return false end
    end
    return true
end

-- ItemVisuals is an ordered render list, not a map.  Keep the same broad
-- order used by the reference implementation so shoes/hat remain on top of
-- the body and the packaged body visual is inserted at its declared slot.
local visualLocationOrder = {
    UnderwearBottom = 10, UnderwearTop = 11, UnderwearExtra1 = 12,
    UnderwearExtra2 = 13, Underwear = 14, Hat = 20, FullHat = 21,
    Pants = 30, Pants_Skinny = 31, Shirt = 40, ShortSleeveShirt = 41,
    Shoes = 90, FullSuit = 100, BodyCostume = 100
}

local function visualOrder(entry)
    local location = tostring(entry.location or "")
    return visualLocationOrder[location] or 50
end

-- Declared before the outfit builder so the renderer diagnostic can use the
-- same asset lookup as the single-item fallback below.  The implementation is
-- assigned after the outfit builder because it also handles ScriptManager
-- point-release differences.
local clothingAssetFor

local function applyConfiguredOutfit(zombie)
    local requested = Config.npcOutfitItems
    if type(requested) ~= "table" or #requested == 0 then
        return false, "no configured clothing items"
    end

    call(zombie, "setAsSurvivor")
    local dressed = call(zombie, "dressInNamedOutfit", Config.npcOutfit)
    if not dressed then call(zombie, "setOutfit", Config.npcOutfit) end
    call(zombie, "setFemaleEtc", false)
    call(zombie, "setSkeleton", false)
    call(zombie, "setCrawler", false)
    call(zombie, "setFakeDead", false)
    call(zombie, "setReanimatedPlayer", false)

    local okInventory, inventory = call(zombie, "getInventory")
    local resolved = {}
    local missing = {}
    local visualType = Config.npcVisualItemType
    if okInventory and inventory ~= nil then
        -- The full-body Mystery Rig is a real clothing item, not a label. Put
        -- it in the same replicated worn collection as the requested pieces
        -- so the client renderer selects the custom FBX instead of leaving an
        -- ordinary zombie shell underneath the four vanilla items.
        if type(visualType) == "string" and visualType ~= "" then
            local visualEntry, visualError = resolveWornItem(inventory, visualType)
            if visualEntry ~= nil then
                visualEntry.isMesh = true
                resolved[#resolved + 1] = visualEntry
            else
                missing[#missing + 1] = visualError
            end
        end
        for index = 1, #requested do
            local fullType = requested[index]
            local entry, itemError = resolveWornItem(inventory, fullType)
            if entry ~= nil then
                resolved[#resolved + 1] = entry
            else
                missing[#missing + 1] = itemError
            end
        end
    else
        missing[#missing + 1] = "inventory-unavailable"
    end

    if #resolved == 0 then
        return false, "no clothing entries resolved|missing=" .. table.concat(missing, ",")
    end

    local okVisuals, visuals = call(zombie, "getItemVisuals")
    if not okVisuals or visuals == nil then
        return false, "getItemVisuals unavailable"
    end

    -- Build 42's native clothing path clears WornItems and constructs the
    -- ItemVisual list.  setWornItem only changes the replicated item
    -- collection; it does not guarantee that a streamed IsoZombie renderer
    -- consumes the custom model, which is why the previous implementation
    -- reported success while still drawing a stock zombie.
    local okWornItems, wornItems = call(zombie, "getWornItems")
    if okWornItems and wornItems ~= nil then call(wornItems, "clear") end
    call(visuals, "clear")

    table.sort(resolved, function(left, right)
        local leftOrder, rightOrder = visualOrder(left), visualOrder(right)
        if leftOrder == rightOrder then return left.fullType < right.fullType end
        return leftOrder < rightOrder
    end)

    local appended = 0
    local customVisual = nil
    for index = 1, #resolved do
        local entry = resolved[index]
        local visual, visualError = newItemVisual(entry.fullType)
        if visual == nil then
            missing[#missing + 1] = tostring(entry.fullType) .. ":" .. tostring(visualError)
        else
            -- Do not attach the temporary InventoryItem here.  The direct
            -- type/name ItemVisual is the path used by the reference mod and
            -- lets the renderer resolve the registered ClothingItem on reset.
            local okAdded, addResult = pcall(function() return visuals:add(visual) end)
            if not okAdded or addResult == false then
                missing[#missing + 1] = tostring(entry.fullType) .. ":ItemVisuals:add-failed"
            else
                appended = appended + 1
                if entry.isMesh then customVisual = visual end
                -- Initialize selectors when the item registry can resolve the
                -- asset.  This is optional; resetModel also initializes them
                -- from the type/name pair, but doing it here makes failures
                -- visible in the diagnostics below.
                local okAsset, asset = call(entry.item, "getClothingItem")
                if okAsset and asset ~= nil then
                    call(visual, "pickUninitializedValues", asset)
                end
            end
        end
    end

    call(zombie, "resetModelNextFrame")
    call(zombie, "resetModel")

    local customType = type(Config.npcVisualItemType) == "string"
        and Config.npcVisualItemType or ""
    local customPresent = customType == "" or visualsContain(visuals, customType)
    local outfitPresent = true
    for index = 1, #requested do
        if not visualsContain(visuals, requested[index]) then
            outfitPresent = false
            break
        end
    end
    local okSize, size = call(visuals, "size")
    local customAsset, assetSource = nil, "missing"
    local assetModel, assetTexture, assetBase = "unknown", "unknown", "unknown"
    if customVisual ~= nil and clothingAssetFor ~= nil then
        customAsset, assetSource = clothingAssetFor(customVisual)
        if customAsset ~= nil then
            local okModel, model = call(customAsset, "getMaleModel")
            local okTexture, texture = call(customVisual, "getTextureChoice", customAsset)
            local okBase, base = call(customVisual, "getBaseTexture", customAsset)
            assetModel = tostring(okModel and model or "unknown")
            assetTexture = tostring(okTexture and texture or "unknown")
            assetBase = tostring(okBase and base or "unknown")
        end
    end
    local detail = "mystery-rig=" .. tostring(customPresent)
        .. "|outfit=" .. tostring(outfitPresent) .. "/" .. tostring(#requested)
        .. "|visuals=" .. tostring(okSize and size or appended)
        .. "|visual=" .. tostring(customVisual ~= nil)
        .. "|asset=" .. tostring(customAsset ~= nil)
        .. "|asset-source=" .. tostring(assetSource)
        .. "|model=" .. assetModel
        .. "|texture=" .. assetTexture
        .. "|base=" .. assetBase
        .. "|missing=" .. (#missing > 0 and table.concat(missing, ",") or "none")
    return customPresent and outfitPresent, detail
end

clothingAssetFor = function(itemVisual)
    -- ItemVisual normally keeps the resolved ClothingItem beside the visual.
    -- During the first network snapshot that reference can be absent even
    -- though the script item is already registered, so resolve the same
    -- asset through the script item/ScriptManager as a bounded fallback.
    -- These accessors are Java methods.  Calling them with the direct colon
    -- form matches the vanilla Lua API (and avoids Kahlua treating the Java
    -- proxy as a Lua table when it is indexed through `call`).
    local okAsset, asset = pcall(function() return itemVisual:getClothingItem() end)
    if okAsset and asset ~= nil then return asset, "visual" end

    local okScript, scriptItem = pcall(function() return itemVisual:getScriptItem() end)
    if okScript and scriptItem ~= nil then
        local okScriptAsset, scriptAsset = pcall(function()
            return scriptItem:getClothingItemAsset()
        end)
        if okScriptAsset and scriptAsset ~= nil then return scriptAsset, "script" end
    end

    -- ScriptManager.instance is the lookup used by the vanilla client.  The
    -- global function is retained as a fallback for point releases that do
    -- not expose the singleton table.
    local manager = nil
    local scriptManagerClass = rawget(_G, "ScriptManager")
    if scriptManagerClass ~= nil then
        manager = scriptManagerClass.instance
    end
    if manager == nil then
        local okManager = pcall(function() manager = getScriptManager() end)
        if not okManager then manager = nil end
    end
    if manager ~= nil then
        local registeredItem = nil
        local okItem = pcall(function()
            registeredItem = manager:FindItem(Config.npcVisualItemType)
        end)
        if okItem and registeredItem ~= nil then
            local registeredAsset = nil
            local okRegisteredAsset = pcall(function()
                registeredAsset = registeredItem:getClothingItemAsset()
            end)
            if okRegisteredAsset and registeredAsset ~= nil then
                return registeredAsset, "script-manager"
            end
        end
    end
    return nil, "missing"
end

local function applyMysteryVisual(zombie)
    if type(Config.npcOutfitItems) == "table" and #Config.npcOutfitItems > 0 then
        return applyConfiguredOutfit(zombie)
    end
    -- The server's worn item normally arrives through the native zombie
    -- packet.  The native client visual path is more reliable for a custom
    -- clothing item: it clears the replicated visual lists, creates one
    -- ItemVisual, and lets the clothing renderer resolve the item type/name
    -- during the model reset.  `addBodyVisualFromItemType` is for body
    -- features (hair, scars, etc.), not a full clothing item.
    call(zombie, "setAsSurvivor")
    local dressed = call(zombie, "dressInNamedOutfit", Config.npcOutfit)
    if not dressed then call(zombie, "setOutfit", Config.npcOutfit) end
    call(zombie, "setFemaleEtc", false)
    call(zombie, "setSkeleton", false)
    call(zombie, "setCrawler", false)
    call(zombie, "setFakeDead", false)
    call(zombie, "setReanimatedPlayer", false)

    local okVisuals, visuals = call(zombie, "getItemVisuals")
    if not okVisuals or visuals == nil then
        return false, "getItemVisuals unavailable"
    end
    call(visuals, "clear")

    local itemVisualClass = nil
    local okItemVisualClass = pcall(function() itemVisualClass = ItemVisual end)
    if not okItemVisualClass or itemVisualClass == nil then
        itemVisualClass = rawget(_G, "ItemVisual")
    end
    if itemVisualClass == nil then return false, "ItemVisual unavailable" end

    -- Create one ItemVisual, set both the full script item type and the
    -- clothing-item name, then insert it into the native ItemVisuals
    -- collection.  This is the path the renderer uses for custom clothing
    -- models and texture choices.
    local itemVisual = nil
    local okCreated = pcall(function() itemVisual = itemVisualClass.new() end)
    if not okCreated or itemVisual == nil then
        return false, "ItemVisual.new failed"
    end
    local okItemType = pcall(function()
        itemVisual:setItemType(Config.npcVisualItemType)
    end)
    local okClothingName = pcall(function()
        itemVisual:setClothingItemName(Config.npcVisualItemType)
    end)
    if not okItemType or not okClothingName then
        return false, "ItemVisual setters failed"
    end
    -- Keep an actual InventoryItem attached to the visual when the client has
    -- the script registry available.  A custom item can otherwise remain a
    -- white shell: the renderer sees the type/name strings while the visual's
    -- clothing asset and texture selectors stay uninitialized.
    local instanceAvailable = false
    local inventoryItem = nil
    local okInstance = pcall(function()
        inventoryItem = instanceItem(Config.npcVisualItemType)
    end)
    if okInstance and inventoryItem ~= nil then
        instanceAvailable = true
        pcall(function() itemVisual:setInventoryItem(inventoryItem) end)
    end

    local okInserted = pcall(function() visuals:add(itemVisual) end)
    if not okInserted then return false, "ItemVisuals:add failed" end

    -- Clear the stale server-side worn list after the custom visual has been
    -- captured.  The ItemVisual is the authoritative client render input;
    -- keeping both lists can leave the default white survivor shell layered
    -- over the custom model.
    local okWornItems, wornItems = call(zombie, "getWornItems")
    if okWornItems and wornItems ~= nil then call(wornItems, "clear") end
    call(zombie, "resetModelNextFrame")
    call(zombie, "resetModel")

    -- The no-argument ItemVisual selectors are the serialized integer slots;
    -- -1 means the visual has not selected a ClothingItem texture yet.  The
    -- renderer uses the ClothingItem overloads, so resolve the asset and let
    -- the engine initialize those slots before resetting the model.
    local clothingAsset, assetSource = clothingAssetFor(itemVisual)
    local picked = false
    if clothingAsset ~= nil then
        local okPick = call(itemVisual, "pickUninitializedValues", clothingAsset)
        picked = okPick == true
    end
    call(zombie, "resetModelNextFrame")
    call(zombie, "resetModel")

    -- Keep the log scalar and renderer-relevant.  ItemVisual exposes both the
    -- raw selectors and ClothingItem-resolved paths; this distinguishes a
    -- registered visual from a model whose texture was never selected.
    local okClothingName, clothingName = call(itemVisual, "getClothingItemName")
    local okItemType, itemType = call(itemVisual, "getItemType")
    local okTextureChoice, textureChoice = call(itemVisual, "getTextureChoice")
    local okBaseTexture, baseTexture = call(itemVisual, "getBaseTexture")
    local okResolvedTexture, resolvedTexture = false, nil
    local okResolvedBase, resolvedBase = false, nil
    local okMaleModel, maleModel = false, nil
    if clothingAsset ~= nil then
        okResolvedTexture, resolvedTexture = call(itemVisual, "getTextureChoice", clothingAsset)
        okResolvedBase, resolvedBase = call(itemVisual, "getBaseTexture", clothingAsset)
        okMaleModel, maleModel = call(clothingAsset, "getMaleModel")
    end
    local okVisualSize, visualSize = call(visuals, "size")
    return true, table.concat({
        tostring(okItemType and itemType or "unknown"),
        tostring(okClothingName and clothingName or "unknown"),
        "texture=" .. tostring(okTextureChoice and textureChoice or "unknown"),
        "base=" .. tostring(okBaseTexture and baseTexture or "unknown"),
        "resolved=" .. tostring(okResolvedTexture and resolvedTexture or "unknown"),
        "resolvedBase=" .. tostring(okResolvedBase and resolvedBase or "unknown"),
        "asset=" .. tostring(assetSource),
        "model=" .. tostring(okMaleModel and maleModel or "unknown"),
        "picked=" .. tostring(picked),
        "instance=" .. tostring(instanceAvailable),
        "count=" .. tostring(okVisualSize and visualSize or "unknown")
    }, "|")
end

local function applyAnimationState(zombie, state)
    local task = state ~= nil and state.task or "FOLLOW"
    local physical = state ~= nil and state.physical_state or "IDLE"
    local moveType = state ~= nil and state.move_type or "IDLE"
    local combat = state ~= nil and state.combat_state or "NONE"
    local recovery = state ~= nil and state.recovery_stage or ""
    local running = moveType == "RUN"
    local moving = physical == "PATHING" or physical == "WALKING"
        or physical == "RUNNING"
    local attacking = physical == "ATTACKING" or combat == "ATTACKING"

    call(zombie, "setVariable", "GoblinNPC", true)
    call(zombie, "setVariable", "GoblinID", Config.npcId)
    call(zombie, "setVariable", "GoblinHumanized", true)
    call(zombie, "setVariable", "GoblinTask", task)
    call(zombie, "setVariable", "GoblinMoveType", moveType)
    call(zombie, "setVariable", "GoblinCombatState", combat)
    call(zombie, "setVariable", "GoblinPhysicalState", physical)
    call(zombie, "setVariable", "GoblinRecoveryStage", recovery)
    call(zombie, "setVariable", "bMoving", moving)
    -- bLunge is a read-only action-group condition in Build 42.  The public
    -- NoLunge* guards below are the supported way to keep a streamed goblin
    -- out of the native bite/lunge path.
    call(zombie, "setVariable", "NoLungeAttack", true)
    call(zombie, "setVariable", "NoLungeTarget", true)
    call(zombie, "setVariable", "ZombieHitReaction", "Chainsaw")
    call(zombie, "setVariable", "isAiming", false)
    call(zombie, "setVariable", "isAttacking", attacking)
    call(zombie, "setVariable", "isMelee", attacking)
    call(zombie, "setVariable", "AttackAnim", attacking)
    call(zombie, "setVariable", "initiateAttack", attacking)
    call(zombie, "setPerformingAttackAnimation", attacking)

    -- These native speed selectors choose the engine's Bob_* walk/run clips
    -- without forcing a frame or a coordinate from Lua.
    local walkType = running and "sprint" or "Walk"
    call(zombie, "setWalkType", walkType)
    call(zombie, "setSpeedTypeFromWalkType")
    call(zombie, "setRunning", running)
    call(zombie, "setSprinting", false)
end

-- After an IsoZombie is marked human, the client also fences off the engine's
-- hostile action-state machine.  Animation variables alone are not a target
-- lock.  The vanilla update can repopulate an IsoZombie target between two
-- callbacks and move it through turnalerted -> lunge -> attack, which is the
-- zombie animation sequence seen in the live Goblin trace.
local function idleStateInstance()
    -- Built-in Java globals are not consistently visible through rawget(_G,
    -- ...), while a direct global read is still resolved by Kahlua.  This is
    -- the same two-step lookup used for addZombiesInOutfit on the server.
    local idleClass = nil
    local okGlobal = pcall(function() idleClass = ZombieIdleState end)
    if not okGlobal or idleClass == nil then
        idleClass = rawget(_G, "ZombieIdleState")
    end
    if idleClass == nil then
        return nil
    end
    -- Kahlua may expose a Java static method as a callable proxy rather than
    -- a Lua `function`; checking its type rejects the exact Build 42 class we
    -- need.  Let pcall be the capability test instead.
    local ok, state = pcall(function() return idleClass.instance() end)
    return ok and state or nil
end

local function forceNativeIdle(zombie)
    -- Build 42 has two state layers.  `getActionStateName()` reports the
    -- action-group layer (the one that actually renders lunge/attack), while
    -- `changeState(ZombieIdleState.instance())` is the public Lua transition
    -- available to mods.  ActionContext is returned as a Java proxy rather
    -- than a Lua-callable table, so do not index it here; use the supported
    -- legacy lookup/transition and retain the conservative fallback below.
    local requested = false
    -- `tryGetAIState` is the supported public lookup for the legacy
    -- ZombieIdleState and avoids indexing a Java StateMachine proxy.
    local idle = nil
    local okTry = pcall(function() idle = zombie:tryGetAIState("idle") end)
    if not okTry or idle == nil then idle = idleStateInstance() end
    if idle ~= nil then
        local okDirectChanged = pcall(function() zombie:changeState(idle) end)
        if okDirectChanged then requested = true end
    end
    if requested then
        call(zombie, "setTarget", nil)
        call(zombie, "setUseless", false)
        call(zombie, "resetModelNextFrame")
    end
    return requested
end

local function clearNativeTargets(zombie)
    call(zombie, "setTarget", nil)
    call(zombie, "setThumpTarget", nil)
    call(zombie, "setAttackTargetSquare", nil)
    call(zombie, "setEatBodyTarget", nil, false)
    call(zombie, "clearAggroList")
end

local function manageNativeActionState(zombie, state)
    local okAction, action = call(zombie, "getActionStateName")
    action = string.lower(tostring(okAction and action or ""))

    -- Our melee uses the normal `zombie/attack` animation state with a Goblin
    -- condition.  Leave that state alone while the authoritative brain has a
    -- real attack pose active; every other native attack is a bite/lunge
    -- attempt and must be cancelled.
    local ownAttack = state ~= nil
        and (state.physical_state == "ATTACKING" or state.combat_state == "ATTACKING")
    if action == "turnalerted" then
        forceNativeIdle(zombie)
        clearNativeTargets(zombie)
        call(zombie, "setUseless", false)
        return
    elseif action == "lunge" or (action == "attack" and not ownAttack) then
        clearNativeTargets(zombie)
        -- `changeState` is the clean path when the built-in state class is
        -- available.  Use the conservative useless fallback for point
        -- releases where the Lua state object is not exposed; it prevents the
        -- native bite from continuing while the next network update arrives.
        local changed = forceNativeIdle(zombie)
        if changed then
            clearNativeTargets(zombie)
            call(zombie, "setUseless", false)
        else
            call(zombie, "setUseless", true)
        end
        local okAfterAction, afterAction = call(zombie, "getActionStateName")
        local okAfterAnimation, afterAnimation = call(zombie, "getAnimationStateName")
        local okAfterContext, afterContext = call(zombie, "getCurrentActionContextStateName")
        local actionSignature = action .. "|idle=" .. tostring(changed)
            .. "|after=" .. tostring(okAfterAction and afterAction or "unknown")
            .. "|context=" .. tostring(okAfterContext and afterContext or "unknown")
            .. "|animation=" .. tostring(okAfterAnimation and afterAnimation or "unknown")
        if actionSignature ~= Client.lastNativeActionSignature then
            Client.lastNativeActionSignature = actionSignature
            log("CLIENT_NATIVE_ACTION id=" .. Config.npcId
                .. " action=" .. action .. " idle=" .. tostring(changed)
                .. " after=" .. tostring(okAfterAction and afterAction or "unknown")
                .. " context=" .. tostring(okAfterContext and afterContext or "unknown")
                .. " animation=" .. tostring(okAfterAnimation and afterAnimation or "unknown"))
        end
        return
    end

    -- The Goblin brain keeps its semantic target in Lua and deliberately
    -- never assigns IsoZombie's hostile target.  Clear any target the vanilla
    -- update may have restored, but leave native pathfind/walk states alive.
    clearNativeTargets(zombie)
    call(zombie, "setUseless", false)
end

local function apply(zombie)
    if not isGoblin(zombie) then return false end
    local state = stateFor(zombie) or {}
    -- This must run before the state-signature fast path: the native AI can
    -- change action state every frame even when the replicated Goblin state
    -- has not changed.
    manageNativeActionState(zombie, state)
    local signature = stateSignature(state)
    local timestamp = nowMs()
    local last = Client.lastInvariantAt[zombie] or 0
    local expectedVisualsPresent = hasExpectedVisuals(zombie)
    if timestamp - last < 500 and Client.lastStateSignature[zombie] == signature
        and expectedVisualsPresent then
        return true
    end
    Client.lastInvariantAt[zombie] = timestamp
    Client.lastStateSignature[zombie] = signature
    applyAnimationState(zombie, state)
    call(zombie, "setCanWalk", true)
    call(zombie, "setCrawler", false)
    call(zombie, "setFakeDead", false)
    call(zombie, "setReanimatedPlayer", false)
    call(zombie, "setBite", false)
    call(zombie, "setCantBite", true)
    call(zombie, "setNoTeeth", true)
    call(zombie, "setZombiesDontAttack", true)
    call(zombie, "setVoiceSoundName", "")
    call(zombie, "setBiteSoundName", "")
    local visualKey = visualSignature(state)
    -- Native streaming can restore the zombie's serialized visual list after
    -- this hook has already run.  Never trust the old cache when the expected
    -- custom visual or one of the requested outfit pieces disappeared.
    if Client.visualApplied[zombie] == visualKey and not expectedVisualsPresent then
        Client.visualApplied[zombie] = nil
    end
    if Client.visualApplied[zombie] ~= visualKey then
        local lastVisualAttempt = Client.visualLastAttemptAt[zombie] or 0
        if timestamp - lastVisualAttempt >= 1000 then
            Client.visualLastAttemptAt[zombie] = timestamp
            local visualOk, visualDetail = applyMysteryVisual(zombie)
            local renderedVisualsPresent = hasExpectedVisuals(zombie)
            if visualOk and renderedVisualsPresent then
                Client.visualApplied[zombie] = visualKey
            end
            log("CLIENT_GOBLIN_RENDER id=" .. Config.npcId
                .. " present=" .. tostring(renderedVisualsPresent)
                .. " detail=" .. tostring(visualDetail))
            log("CLIENT_GOBLIN_APPLY id=" .. Config.npcId
                .. " persistent=" .. tostring(persistentOutfitId(zombie))
                .. " online=" .. tostring(onlineId(zombie))
                .. " asset=" .. tostring(state.visual_asset or Config.npcVisualAsset)
                .. " visual=" .. tostring(visualOk)
                .. " detail=" .. tostring(visualDetail))
        end
    end

    -- Keep one diagnostic sample per actual animator state without turning
    -- OnZombieUpdate into a log stream.
    local okAnimation, animationState = call(zombie, "getAnimationStateName")
    local okDebug, animationDebug = call(zombie, "getAnimationDebug")
    -- getAnimationDebug() is a multiline dump whose weights/angles change on
    -- every frame.  It is useful for one compact sample, but must not be the
    -- cache key or the client log becomes a per-frame trace.
    local debugText = tostring(okDebug and animationDebug or "unknown")
    local debugFirstLine = string.match(debugText, "^[^\\r\\n]*") or debugText
    local animationName = string.lower(string.match(
        tostring(okAnimation and animationState or "unknown"), "^[^\\r\\n|]+"
    ) or "unknown")
    local animationSignature = animationName
    if Client.lastAnimationSignature ~= animationSignature
        or timestamp - (Client.lastAnimationLogAt or 0) >= 5000 then
        Client.lastAnimationSignature = animationSignature
        Client.lastAnimationLogAt = timestamp
        log("CLIENT_ANIMATION id=" .. Config.npcId
            .. " state=" .. tostring(okAnimation and animationState or "unknown")
            .. " debug=" .. string.sub(debugFirstLine, 1, 80))
    end
    return true
end

local function scanZombies()
    iterateZombies(apply)
end

local function onReceiveGlobalModData(key, data)
    if key ~= "GoblinCompanion" or data == nil then return end
    local receivedSignature = tostring(data.body_present == true) .. "|" .. stateSignature(data)
    if receivedSignature == Client.lastReceivedSignature then return end
    Client.lastReceivedSignature = receivedSignature
    Client.globalState = data
    Client.globalRevision = Client.globalRevision + 1
    local identitySignature = table.concat({
        tostring(data.body_present == true), tostring(data.generation or 0),
        tostring(data.persistent_outfit_id), tostring(data.online_id)
    }, "|")
    if identitySignature ~= Client.lastLoggedGlobalIdentity then
        Client.lastLoggedGlobalIdentity = identitySignature
        log("CLIENT_GLOBAL_STATE id=" .. Config.npcId
            .. " present=" .. tostring(data.body_present == true)
            .. " generation=" .. tostring(data.generation or 0)
            .. " persistent=" .. tostring(data.persistent_outfit_id)
            .. " online=" .. tostring(data.online_id))
    end
    scanZombies()
end

local function onInitGlobalModData()
    requestGlobalState()
end

local function onTick()
    local timestamp = nowMs()
    if Client.globalState ~= nil and timestamp - Client.lastScanAt >= 1000 then
        Client.lastScanAt = timestamp
        scanZombies()
    end
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
    local author = nil
    local text = nil
    if message ~= nil then
        local okAuthor, valueAuthor = pcall(function() return message:getAuthor() end)
        local okText, valueText = pcall(function() return message:getText() end)
        if okAuthor then author = valueAuthor end
        if okText then text = valueText end
    end
    local localName = localUsername()
    text = cleanText(text)
    if author == nil or text == nil or localName == nil
        or string.lower(tostring(author)) ~= string.lower(localName) then return end
    local lower = string.lower(text)
    local command = string.match(lower, "^%s*[/!]goblin%s+(.+)$")
    if command ~= nil then
        send("debug", { text = "/goblin " .. command })
        return
    end
    if string.find(lower, "goblin", 1, true) ~= nil then
        send("chat", { text = text, tab_id = type(tabId) == "number" and tabId or 0 })
    end
end

if Events ~= nil then
    EventHooks.install("client.global_data_init", Events.OnInitGlobalModData, onInitGlobalModData)
    EventHooks.install("client.global_data_receive", Events.OnReceiveGlobalModData, onReceiveGlobalModData)
    EventHooks.install("client.zombie_create", Events.OnZombieCreate, apply)
    -- Re-register the update callback so the action-state fence runs after
    -- the vanilla zombie update.  If it is registered too early, the engine
    -- can enter lunge/attack immediately after our target clear and leave the
    -- body frozen in that pose for the next frame.
    EventHooks.install("client.zombie_update", Events.OnZombieUpdate, apply)
    EventHooks.install("client.tick", Events.OnTick, onTick)
    EventHooks.install("client.chat_message", Events.OnAddMessage, onMessage)
end

-- A client can load this module after OnInitGlobalModData during a hot
-- reload; requesting once here is harmless and keeps the initial state path
-- deterministic in both fresh and resumed multiplayer sessions.
requestGlobalState()

return Client
