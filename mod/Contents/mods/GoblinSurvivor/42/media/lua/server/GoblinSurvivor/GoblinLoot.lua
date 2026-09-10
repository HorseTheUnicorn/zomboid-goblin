-- Bounded, server-authoritative ground-loot worker.
--
-- The worker only transfers an InventoryItem that already exists in a loaded
-- square's world-object list.  It never creates a requested item, accepts a
-- coordinate from Qwen, or scans an unbounded area.  The normal PZ world-item
-- removal sequence is used so the transfer replicates to connected clients.
local Config = require("GoblinSurvivor/Config")
local Body = require("GoblinSurvivor/GoblinBody")

local Loot = {}

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
    if type(print) == "function" then print("[GoblinSurvivor] " .. tostring(message)) end
end

local function currentCell()
    local worldClass = rawget(_G, "IsoWorld")
    local world = worldClass ~= nil and worldClass.instance or nil
    local cell = world ~= nil and world.currentCell or nil
    if cell ~= nil then return cell end
    if type(getCell) == "function" then
        local ok, value = pcall(getCell)
        if ok then return value end
    end
    return nil
end

local function collectionValues(collection)
    if collection == nil then return {} end
    local count = type(collection.size) == "function" and collection:size() or #collection
    local result = {}
    for index = 0, count - 1 do
        local value = type(collection.get) == "function"
            and collection:get(index) or collection[index + 1]
        if value ~= nil then result[#result + 1] = value end
    end
    return result
end

local function itemCategory(item)
    local ok, value = call(item, "getCategory")
    return ok and type(value) == "string" and string.lower(value) or ""
end

local function itemBoolean(item, method)
    local ok, value = call(item, method)
    return ok and value == true
end

local function usefulForFocus(item, focus)
    focus = type(focus) == "string" and string.lower(focus) or "surprise"
    if focus == "surprise" then return true end
    local category = itemCategory(item)
    if focus == "food" then
        return itemBoolean(item, "isFood") or string.find(category, "food", 1, true) ~= nil
    end
    if focus == "medical" then
        return itemBoolean(item, "isMedical")
            or string.find(category, "firstaid", 1, true) ~= nil
            or string.find(category, "medical", 1, true) ~= nil
    end
    if focus == "tools" then
        return itemBoolean(item, "isTool") or string.find(category, "tool", 1, true) ~= nil
    end
    if focus == "ammo" then
        return itemBoolean(item, "isAmmo") or string.find(category, "ammo", 1, true) ~= nil
    end
    return false
end

local function forbiddenItem(item)
    local okType, fullType = call(item, "getFullType")
    if not okType or type(fullType) ~= "string" then return true end
    if fullType == Config.weaponType or fullType == Config.npcVisualItemType then return true end
    -- The companion may only be equipped with the configured Machete.  Other
    -- weapons are left in the world rather than being silently stockpiled.
    local category = itemCategory(item)
    return itemBoolean(item, "isWeapon") or string.find(category, "weapon", 1, true) ~= nil
end

local function transfer(body, square, worldObject, item)
    local okInventory, inventory = call(body, "getInventory")
    if not okInventory or inventory == nil or type(inventory.AddItem) ~= "function" then
        return false, "inventory transfer API is unavailable"
    end
    local okRoom, hasRoom = call(inventory, "hasRoomFor", body, item)
    if okRoom and hasRoom == false then return false, "Goblin inventory is full" end
    if type(worldObject.removeFromWorld) ~= "function"
        or type(worldObject.removeFromSquare) ~= "function" then
        return false, "world-item removal API is unavailable"
    end
    -- Match PZ's own ISGrabItemAction order.  All calls are capability-gated;
    -- AddItem(item) receives the real world InventoryItem, never a type string.
    call(square, "transmitRemoveItemFromSquare", worldObject)
    local okWorld = select(1, call(worldObject, "removeFromWorld"))
    local okSquare = select(1, call(worldObject, "removeFromSquare"))
    if not okWorld or not okSquare then
        return false, "world-item removal failed"
    end
    call(worldObject, "setSquare", nil)
    call(item, "setWorldItem", nil)
    local okAdd = select(1, call(inventory, "AddItem", item))
    if not okAdd then return false, "inventory rejected world item" end
    return true, "real world item transferred"
end

function Loot.scan(body, payload, timestamp)
    if not Body.isGoblin(body) then return false, "body is not Goblin" end
    local bodyData = Body.data(body)
    if bodyData == nil then return false, "Goblin ModData is unavailable" end
    local now = timestamp or nowMs()
    local nextScan = tonumber(bodyData.GoblinLootNextScanAt) or 0
    if now < nextScan then return true, "loot scan cooldown active" end
    bodyData.GoblinLootNextScanAt = now
        + (tonumber(Config.lootScanSeconds) or 2) * 1000
    local origin = Body.position(body)
    local cell = currentCell()
    if origin == nil or cell == nil or type(cell.getGridSquare) ~= "function" then
        bodyData.GoblinLootStatus = "world-scan-unavailable"
        return false, "world-item scan API is unavailable"
    end
    local radius = math.floor(tonumber(Config.lootRadius) or 6)
    local maximum = math.floor(tonumber(Config.lootMaxItemsPerTask) or 4)
    local focus = type(payload) == "table" and payload.loot_focus or "surprise"
    local moved, seen = 0, 0
    for dx = -radius, radius do
        for dy = -radius, radius do
            if moved >= maximum then break end
            local okSquare, square = pcall(cell.getGridSquare, cell,
                math.floor(origin.x) + dx, math.floor(origin.y) + dy, math.floor(origin.z))
            if okSquare and square ~= nil then
                local okObjects, objects = call(square, "getWorldObjects")
                if okObjects and objects ~= nil then
                    for _, worldObject in ipairs(collectionValues(objects)) do
                        if moved >= maximum then break end
                        local okItem, item = call(worldObject, "getItem")
                        if okItem and item ~= nil then
                            seen = seen + 1
                            if not forbiddenItem(item) and usefulForFocus(item, focus) then
                                local movedItem = transfer(body, square, worldObject, item)
                                if movedItem then
                                    moved = moved + 1
                                    local okType, fullType = call(item, "getFullType")
                                    bodyData.GoblinLootLastType = okType and fullType or "unknown"
                                    bodyData.GoblinLootCount =
                                        (tonumber(bodyData.GoblinLootCount) or 0) + 1
                                end
                            end
                        end
                    end
                end
            end
        end
        if moved >= maximum then break end
    end
    bodyData.GoblinLootLastAt = now
    bodyData.GoblinLootStatus = moved > 0 and "items-transferred" or
        (seen > 0 and "items-seen-none-eligible" or "no-world-items")
    log("LOOT_SCAN id=" .. Config.npcId .. " focus=" .. tostring(focus)
        .. " seen=" .. tostring(seen) .. " moved=" .. tostring(moved))
    return true, bodyData.GoblinLootStatus
end

return Loot
