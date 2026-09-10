-- Real item collection and base delivery for a managed Goblin.
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

local function log(body, text)
    if type(print) == "function" then
        print("[GoblinSurvivor] " .. tostring(text) .. " owner=" .. tostring(Body.owner(body)))
    end
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

local function values(collection)
    local result = {}
    if collection == nil then return result end
    local okSize, size = call(collection, "size")
    size = okSize and tonumber(size) or 0
    for index = 0, size - 1 do
        local ok, value = call(collection, "get", index)
        if ok and value ~= nil then result[#result + 1] = value end
    end
    return result
end

local function fullType(item)
    local ok, value = call(item, "getFullType")
    return ok and type(value) == "string" and value or nil
end

local function protectedType(item)
    local itemType = fullType(item)
    if itemType == nil then return true end
    if itemType == Config.weaponType or itemType == Config.npcVisualItemType then return true end
    for _, clothing in ipairs(Config.npcOutfitItems or {}) do
        if itemType == clothing then return true end
    end
    return false
end

local function category(item)
    local ok, value = call(item, "getCategory")
    return ok and type(value) == "string" and string.lower(value) or ""
end

local function truth(item, method)
    local ok, value = call(item, method)
    return ok and value == true
end

local function matchesFocus(item, focus)
    if protectedType(item) then return false end
    focus = type(focus) == "string" and string.lower(focus) or "surprise"
    local c = category(item)
    if focus == "surprise" then return true end
    if focus == "food" then
        return truth(item, "isFood") or string.find(c, "food", 1, true) ~= nil
    end
    if focus == "medical" then
        return truth(item, "isMedical") or string.find(c, "medical", 1, true) ~= nil
            or string.find(c, "firstaid", 1, true) ~= nil
    end
    if focus == "tools" then
        return truth(item, "isTool") or truth(item, "isWeapon")
            or string.find(c, "tool", 1, true) ~= nil
            or string.find(c, "weapon", 1, true) ~= nil
    end
    if focus == "ammo" then
        return truth(item, "isAmmo") or string.find(c, "ammo", 1, true) ~= nil
    end
    return true
end

local function bodyInventory(body)
    local ok, inventory = call(body, "getInventory")
    return ok and inventory or nil
end

local function canCarry(inventory, body, item)
    local ok, value = call(inventory, "hasRoomFor", body, item)
    return not ok or value ~= false
end

local function transferGround(body, inventory, square, worldObject, item)
    if not canCarry(inventory, body, item) then return false end
    call(square, "transmitRemoveItemFromSquare", worldObject)
    local okWorld = select(1, call(worldObject, "removeFromWorld"))
    local okSquare = select(1, call(worldObject, "removeFromSquare"))
    if not okWorld or not okSquare then return false end
    call(worldObject, "setSquare", nil)
    call(item, "setWorldItem", nil)
    local okAdd, result = call(inventory, "AddItem", item)
    return okAdd and result ~= false
end

local function sendRemove(container, item)
    local fn = rawget(_G, "sendRemoveItemFromContainer")
    if type(fn) == "function" then pcall(fn, container, item) end
end

local function sendAdd(container, item)
    local fn = rawget(_G, "sendAddItemToContainer")
    if type(fn) == "function" then pcall(fn, container, item) end
end

local function transferContainer(body, inventory, container, item)
    if not canCarry(inventory, body, item) then return false end
    sendRemove(container, item)
    local okRemove = select(1, call(container, "Remove", item))
    if not okRemove then return false end
    local okAdd, result = call(inventory, "AddItem", item)
    if okAdd and result ~= false then return true end
    call(container, "AddItem", item)
    sendAdd(container, item)
    return false
end

local function objectContainer(object)
    local ok, container = call(object, "getContainer")
    if ok and container ~= nil then return container end
    ok, container = call(object, "getItemContainer")
    if ok and container ~= nil then return container end
    return nil
end

function Loot.collect(body, payload, timestamp)
    if not Body.isGoblin(body) then return false, "body is not Goblin", 0 end
    local data = Body.data(body)
    local inventory = bodyInventory(body)
    local origin = Body.position(body)
    local cell = currentCell()
    if data == nil or inventory == nil or origin == nil or cell == nil then
        return false, "loot world state unavailable", 0
    end
    local now = timestamp or nowMs()
    if now < (tonumber(data.GoblinLootNextScanAt) or 0) then
        return true, "loot scan cooldown", 0
    end
    data.GoblinLootNextScanAt = now + (tonumber(Config.lootScanSeconds) or 2) * 1000

    local radius = math.floor(tonumber(Config.lootRadius) or 6)
    local maximum = math.floor(tonumber(Config.lootMaxItemsPerTask) or 8)
    local focus = type(payload) == "table" and payload.loot_focus or "surprise"
    local moved = 0

    for dx = -radius, radius do
        for dy = -radius, radius do
            if moved >= maximum then break end
            local okSquare, square = call(cell, "getGridSquare",
                math.floor(origin.x) + dx, math.floor(origin.y) + dy, math.floor(origin.z))
            if okSquare and square ~= nil then
                local okWorld, worldObjects = call(square, "getWorldObjects")
                if okWorld and worldObjects ~= nil then
                    for _, worldObject in ipairs(values(worldObjects)) do
                        if moved >= maximum then break end
                        local okItem, item = call(worldObject, "getItem")
                        if okItem and item ~= nil and matchesFocus(item, focus)
                            and transferGround(body, inventory, square, worldObject, item) then
                            moved = moved + 1
                        end
                    end
                end

                if moved < maximum then
                    local okObjects, objects = call(square, "getObjects")
                    if okObjects and objects ~= nil then
                        for _, object in ipairs(values(objects)) do
                            if moved >= maximum then break end
                            local container = objectContainer(object)
                            if container ~= nil then
                                local okItems, items = call(container, "getItems")
                                if okItems and items ~= nil then
                                    -- Snapshot first because successful transfers mutate the list.
                                    for _, item in ipairs(values(items)) do
                                        if moved >= maximum then break end
                                        if matchesFocus(item, focus)
                                            and transferContainer(body, inventory, container, item) then
                                            moved = moved + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if moved >= maximum then break end
    end

    data.GoblinLootCount = (tonumber(data.GoblinLootCount) or 0) + moved
    data.GoblinLootStatus = moved > 0 and "carrying-to-base" or "nothing-useful-nearby"
    data.GoblinLootLastAt = now
    log(body, "LOOT_COLLECT focus=" .. tostring(focus) .. " moved=" .. tostring(moved))
    return true, data.GoblinLootStatus, moved
end

function Loot.hasCargo(body)
    local inventory = bodyInventory(body)
    if inventory == nil then return false end
    local okItems, items = call(inventory, "getItems")
    if not okItems or items == nil then return false end
    for _, item in ipairs(values(items)) do
        if not protectedType(item) then return true end
    end
    return false
end

local function baseSquare(body)
    local data = Body.data(body)
    local cell = currentCell()
    if data == nil or cell == nil or data.GoblinBaseSet ~= true then return nil end
    local x, y, z = tonumber(data.GoblinBaseX), tonumber(data.GoblinBaseY), tonumber(data.GoblinBaseZ)
    if x == nil or y == nil or z == nil then return nil end
    local ok, square = call(cell, "getGridSquare", math.floor(x), math.floor(y), math.floor(z))
    return ok and square or nil
end

local function nearbyDepositContainer(body, square)
    if square == nil then return nil end
    local data = Body.data(body)
    local cell = currentCell()
    if data == nil or cell == nil then return nil end
    local bx, by, bz = math.floor(tonumber(data.GoblinBaseX) or 0),
        math.floor(tonumber(data.GoblinBaseY) or 0), math.floor(tonumber(data.GoblinBaseZ) or 0)
    for radius = 0, 2 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                local okSq, sq = call(cell, "getGridSquare", bx + dx, by + dy, bz)
                if okSq and sq ~= nil then
                    local okObjects, objects = call(sq, "getObjects")
                    if okObjects and objects ~= nil then
                        for _, object in ipairs(values(objects)) do
                            local container = objectContainer(object)
                            if container ~= nil then return container end
                        end
                    end
                end
            end
        end
    end
    return nil
end

function Loot.deposit(body)
    if not Body.isGoblin(body) then return false, "body is not Goblin", 0 end
    local inventory = bodyInventory(body)
    local square = baseSquare(body)
    if inventory == nil or square == nil then return false, "base deposit unavailable", 0 end
    local okItems, items = call(inventory, "getItems")
    if not okItems or items == nil then return false, "inventory unavailable", 0 end
    local cargo = {}
    for _, item in ipairs(values(items)) do
        if not protectedType(item) then cargo[#cargo + 1] = item end
    end
    if #cargo == 0 then return true, "nothing to deposit", 0 end

    local container = nearbyDepositContainer(body, square)
    local moved = 0
    for _, item in ipairs(cargo) do
        local okRemove = select(1, call(inventory, "Remove", item))
        if okRemove then
            local delivered = false
            if container ~= nil then
                local okAdd, result = call(container, "AddItem", item)
                delivered = okAdd and result ~= false
                if delivered then sendAdd(container, item) end
            else
                local okWorld, result = call(square, "AddWorldInventoryItem", item, 0.5, 0.5, 0.0)
                delivered = okWorld and result ~= false
            end
            if delivered then
                moved = moved + 1
            else
                call(inventory, "AddItem", item)
            end
        end
    end

    local data = Body.data(body)
    if data ~= nil then
        data.GoblinLootDelivered = (tonumber(data.GoblinLootDelivered) or 0) + moved
        data.GoblinLootStatus = moved > 0 and "delivered" or "deposit-failed"
    end
    log(body, "LOOT_DELIVER moved=" .. tostring(moved)
        .. " destination=" .. (container ~= nil and "container" or "ground"))
    return moved > 0, moved > 0 and "loot delivered to base" or "loot delivery failed", moved
end

return Loot
