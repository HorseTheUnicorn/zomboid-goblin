-- Exact-item custody primitives shared by logistics jobs.
--
-- Every function moves one existing InventoryItem instance and verifies the
-- source and destination by identity afterwards. Nothing here creates items.
-- The Goblin's own inventory belongs to a square-less managed IsoZombie, so
-- actor-inventory packets are never sent (Build 42 rejects them; see
-- STOCKPILE/LOOT evidence). World containers and world squares are synced
-- with the same native packets vanilla timed actions use.
local World = require("GoblinSurvivor/GoblinWorld")
local Tools = require("GoblinSurvivor/GoblinTools")
local Config = require("GoblinSurvivor/Config")

local Transfer = {}
local call = World.call

function Transfer.itemId(item)
    local ok, id = call(item, "getID")
    if ok and type(id) == "number" and id == id then return id end
    return nil
end

-- Reserved toolkit, weapon, uniform and anything held or worn never counts as cargo.
function Transfer.protected(body, item)
    if not item or Tools.reserved(item) then return true end
    local kind = World.fullType(item)
    if type(kind) ~= "string" or kind == Config.weaponType or kind == Config.npcVisualItemType then
        return true
    end
    for _, uniform in ipairs(Config.npcOutfitItems or {}) do
        if kind == uniform then return true end
    end
    if body then
        if select(2, call(body, "isEquipped", item)) == true
            or select(2, call(body, "isEquippedClothing", item)) == true then return true end
        if item == select(2, call(body, "getPrimaryHandItem"))
            or item == select(2, call(body, "getSecondaryHandItem")) then return true end
    end
    local _, data = call(item, "getModData")
    if type(data) == "table" and data.GoblinReserved == true then return true end
    return false
end

function Transfer.movable(body, item)
    return not Transfer.protected(body, item)
end

-- Finds an item by persistent native ID in a container; nil means unreadable.
function Transfer.findById(container, id)
    if type(id) ~= "number" then return nil end
    local loaded, items = call(container, "getItems")
    local sized, size = call(items, "size")
    if not loaded or not items or not sized or type(size) ~= "number"
        or size ~= math.floor(size) or size < 0 or size > 10000 then return nil end
    for index = 0, size - 1 do
        local got, item = call(items, "get", index)
        if not got or not item then return nil end
        if Transfer.itemId(item) == id then return item end
    end
    return false
end

-- Detach an exact item from the managed actor inventory. ItemContainer.Remove
-- calls Food.OnBeforeRemoveFromContainer, which sends ItemStats for a
-- square-less container; DoRemoveItem is the native detach without it.
function Transfer.detach(body, item)
    local inventory = World.inventory(body)
    if World.containsExact(inventory, item) ~= true then return false end
    if item == select(2, call(body, "getPrimaryHandItem")) then call(body, "setPrimaryHandItem", nil) end
    if item == select(2, call(body, "getSecondaryHandItem")) then call(body, "setSecondaryHandItem", nil) end
    local removed = call(inventory, "DoRemoveItem", item)
    if not removed then removed = call(inventory, "Remove", item) end
    return removed and World.containsExact(inventory, item) == false
end

local function restore(body, item)
    local inventory = World.inventory(body)
    if World.containsExact(inventory, item) == true then return true end
    local added, value = call(inventory, "AddItem", item)
    return added and value == item and World.containsExact(inventory, item) == true
end

-- Goblin inventory -> loaded world container. Returns ok, code, detail.
-- code is nil on success, BLOCKED when the destination refused the item, or
-- ENGINE_ERROR when custody cannot be proven either way.
function Transfer.deposit(body, item, container)
    local inventory = World.inventory(body)
    if World.containsExact(inventory, item) ~= true then
        return false, "TARGET_CHANGED", "carried item is no longer in Goblin inventory"
    end
    if World.containsExact(container, item) ~= false then
        return false, "ENGINE_ERROR", "destination already reports this exact item"
    end
    local checked, room = call(container, "hasRoomFor", body, item)
    if not checked or room ~= true then return false, "BLOCKED", "destination container is full" end
    if not Transfer.detach(body, item) then
        return false, "ENGINE_ERROR", "could not detach the exact carried item"
    end
    local added, value = call(container, "AddItem", item)
    local arrived = World.containsExact(container, item)
    -- Build 42 AddItem returns the existing item if the ID is already there,
    -- so only an identical return plus a membership read proves custody.
    if not added or value ~= item or arrived ~= true then
        if arrived == false and restore(body, item) then
            return false, "BLOCKED", "destination refused the item; it stays with Goblin"
        end
        return false, "ENGINE_ERROR", "destination add failed and custody is uncertain"
    end
    local synced = type(sendAddItemToContainer) == "function"
        and pcall(sendAddItemToContainer, container, item)
    if not synced then
        return false, "ENGINE_ERROR", "item stored but replication is uncertain; do not retry blindly"
    end
    return true
end

-- Goblin inventory -> owner inventory (a real IsoPlayer inventory, which does
-- have a valid packet address). Falls back to the owner's square only when
-- allowFloor is true and the player's inventory has no room.
function Transfer.handOver(body, item, player, allowFloor)
    local destination = select(2, call(player, "getInventory"))
    if not destination then return false, "TARGET_UNLOADED", "owner inventory unavailable" end
    local checked, room = call(destination, "hasRoomFor", player, item)
    if checked and room == true then
        if not Transfer.detach(body, item) then
            return false, "ENGINE_ERROR", "could not detach the exact carried item"
        end
        local added, value = call(destination, "AddItem", item)
        local arrived = World.containsExact(destination, item)
        if not added or value ~= item or arrived ~= true then
            if arrived == false and restore(body, item) then
                return false, "BLOCKED", "owner inventory refused the item; it stays with Goblin"
            end
            return false, "ENGINE_ERROR", "hand-over failed and custody is uncertain"
        end
        local synced = type(sendAddItemToContainer) == "function"
            and pcall(sendAddItemToContainer, destination, item)
        if not synced then
            return false, "ENGINE_ERROR", "item handed over but replication is uncertain"
        end
        return true, nil, "handed"
    end
    if not allowFloor then return false, "BLOCKED", "owner cannot carry more" end
    local square = select(2, call(player, "getCurrentSquare"))
    local ok, code, detail = Transfer.drop(body, item, square)
    if ok then return true, nil, "dropped at owner's feet" end
    return false, code, detail
end

-- Goblin inventory -> world floor on an exact loaded square.
function Transfer.drop(body, item, square)
    if not square then return false, "TARGET_UNLOADED", "drop square unloaded" end
    if not Transfer.detach(body, item) then
        return false, "ENGINE_ERROR", "could not detach the exact carried item"
    end
    local added, value = call(square, "AddWorldInventoryItem", item, 0.5, 0.5, 0)
    if not added or value ~= item then
        if restore(body, item) then return false, "BLOCKED", "floor drop refused; item kept" end
        return false, "ENGINE_ERROR", "floor drop failed and custody is uncertain"
    end
    return true
end

-- World container/floor -> Goblin inventory through the existing audited path.
function Transfer.pickup(body, source)
    local ok, moved = pcall(World.take, body, source)
    if not ok then return false, "ENGINE_ERROR", "pickup raised an engine error" end
    local held = World.containsExact(World.inventory(body), source.item)
    if moved then
        if held ~= true then return false, "ENGINE_ERROR", "pickup reported success without the item" end
        return true
    end
    if held == true then
        return false, "ENGINE_ERROR", "pickup moved the item but replication is uncertain"
    end
    return false, "BLOCKED", "source item could not be taken"
end

-- Where is a ledger item now? Returns "carried", "destination", "source",
-- "missing" or "unknown" (unreadable) plus the live item when found.
function Transfer.locate(body, id, destination, source)
    local found = Transfer.findById(World.inventory(body), id)
    if found then return "carried", found end
    if found == nil then return "unknown" end
    if destination then
        local there = Transfer.findById(destination, id)
        if there then return "destination", there end
        if there == nil then return "unknown" end
    end
    if source then
        local back = Transfer.findById(source, id)
        if back then return "source", back end
        if back == nil then return "unknown" end
    end
    return "missing"
end

return Transfer
