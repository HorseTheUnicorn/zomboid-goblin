-- Explicit, bounded stockpile run using real item instances and server movement.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Stockpiles = require("GoblinSurvivor/GoblinStockpiles")
local Tools = require("GoblinSurvivor/GoblinTools")
local Config = require("GoblinSurvivor/Config")

local Work = {}
local call = World.call
local SEARCH_RADIUS = 150 -- Goblin range (World.range); reported in shortages
local MAX_DELIVERIES = 20

local function audit(payload, stage, item, square, before, after)
    if type(print) ~= "function" then return end
    local _, itemId = call(item, "getID")
    local point = square and World.point(square)
    print("[GoblinSurvivor] STOCKPILE_TRANSFER stage="..stage
        .." owner="..tostring(payload.owner)
        .." item="..tostring(payload.item)
        .." item_id="..tostring(itemId)
        .." x="..tostring(point and point.x)
        .." y="..tostring(point and point.y)
        .." z="..tostring(point and point.z)
        .." stock_before="..tostring(before)
        .." stock_after="..tostring(after))
end

local function ownerOnline(name)
    if type(getOnlinePlayers) ~= "function" then return false end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return false end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return true end
    end
    return false
end

local function protected(body, item)
    if not item or Tools.reserved(item) then return true end
    if require("GoblinSurvivor/GoblinProvision").isConjured(item) then return true end
    local kind = World.fullType(item)
    if not kind or kind == Config.weaponType or kind == Config.npcVisualItemType then return true end
    for _, uniform in ipairs(Config.npcOutfitItems or {}) do
        if kind == uniform then return true end
    end
    if select(2, call(body, "isEquipped", item)) == true
        or select(2, call(body, "isEquippedClothing", item)) == true then return true end
    if item == select(2, call(body, "getPrimaryHandItem"))
        or item == select(2, call(body, "getSecondaryHandItem")) then return true end
    return false
end

local function rowFor(report, fullType)
    for _, row in ipairs(report.items or {}) do
        if row.item == fullType then return row end
    end
    return nil
end

local function statusCode(row)
    if not row then return "NO_TARGET" end
    if row.status == "TARGET_UNLOADED" then return "TARGET_UNLOADED" end
    if row.status == "PERMISSION_DENIED" then return "PERMISSION_DENIED" end
    if row.status == "BLOCKED" then return "BLOCKED" end
    return "TARGET_CHANGED"
end

local function targetFor(body, payload)
    local scope = Curtains.scopeAt(payload.anchor)
    if not scope or scope.id ~= payload.building_id then
        return nil, nil, "TARGET_UNLOADED"
    end
    local target, failure = Stockpiles.target(scope, body, payload.item)
    if not target then return nil, scope, failure end
    if target.id ~= payload.target_id then return nil, scope, "TARGET_CHANGED" end
    return target, scope
end

-- A failed inventory read is unknown, never an empty inventory. In particular,
-- do not roll an item back after AddItem if the destination cannot be read.
local function contains(container, item)
    local native, present = call(container, "contains", item)
    if native and type(present) == "boolean" then return present end
    local loaded, items = call(container, "getItems")
    local sized, size = call(items, "size")
    if not loaded or not items or not sized or type(size) ~= "number"
        or size ~= math.floor(size) or size < 0 or size > 10000 then return nil end
    local found = false
    for index = 0, size-1 do
        local checked, current = call(items, "get", index)
        if not checked or not current then return nil end
        if current == item then found = true end
    end
    return found
end

local function carried(body, fullType)
    local inventory = World.inventory(body)
    local loaded, items = call(inventory, "getItems")
    local sized, size = call(items, "size")
    if not loaded or not items or not sized or type(size) ~= "number"
        or size ~= math.floor(size) or size < 0 or size > 10000 then
        return nil, "inventory cannot be read"
    end
    for index = 0, size-1 do
        local checked, item = call(items, "get", index)
        if not checked or not item then return nil, "inventory changed while reading" end
        if World.fullType(item) == fullType and not protected(body, item) then return item end
    end
    return nil
end

local function sourceKey(square)
    local point = World.point(square)
    return math.floor(point.x)..":"..math.floor(point.y)..":"..math.floor(point.z)
end

-- Per job (keyed by its skipped table) and item type: wide searches are cached.
local nearCache = setmetatable({}, { __mode = "k" })

local function sourceFor(body, target, fullType, skipped, skippedSquares, anchor)
    local here = Body.position(body)
    local best, bestDistance
    local caches = nearCache[skipped] or {}
    nearCache[skipped] = caches
    caches[fullType] = caches[fullType] or {}
    for _, source in ipairs(World.cachedNear(caches[fullType], anchor, function(item)
        return World.fullType(item) == fullType and not skipped[item]
            and not protected(body, item)
    end, body)) do
        if source.container ~= target.container and source.object ~= target.object
            and not skippedSquares[sourceKey(source.square)] then
            local point = World.point(source.square)
            local distance = here and ((point.x-here.x)^2+(point.y-here.y)^2) or 0
            if not best or distance < bestDistance then
                best, bestDistance = source, distance
            end
        end
    end
    return best
end

local function transfer(body, item, target)
    local inventory = World.inventory(body)
    if contains(inventory, item) ~= true or contains(target.container, item) ~= false then
        return false, "cargo identity changed before delivery"
    end
    local checked, room = call(target.container, "hasRoomFor", body, item)
    if not checked or room ~= true then return false, "assigned container is full" end
    local removed = call(inventory, "Remove", item)
    if not removed or contains(inventory, item) ~= false then
        return false, "could not remove the exact carried item"
    end
    local added, value = call(target.container, "AddItem", item)
    local atDestination = contains(target.container, item)
    if not added or not value or atDestination ~= true then
        if atDestination == false and contains(inventory, item) == false then
            local rolledBack = call(inventory, "AddItem", item)
            if not rolledBack or contains(inventory, item) ~= true then
                return false, "destination add and rollback failed; item state uncertain"
            end
        end
        return false, "destination add failed; exact item needs reconciliation"
    end
    local syncedAdd = type(sendAddItemToContainer) == "function"
        and pcall(sendAddItemToContainer, target.container, item)
    if not syncedAdd then
        return false, "item reached world storage but replication is uncertain; do not retry blindly"
    end
    return true
end

function Work.prepare(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true
        or request.autonomous == true or type(request.item) ~= "string" then
        return nil, "stockpiling requires an explicit owner order and tracked exact item"
    end
    -- First physical adapter is the exact installed Base.Nails item. Other
    -- tracked types remain read-only until their transfer lifecycle is audited.
    if request.item ~= "Base.Nails" then
        return nil, "physical stockpiling currently supports Base.Nails only; live verification pending"
    end
    local ownerName = select(2, call(owner, "getUsername"))
    if ownerName ~= Body.owner(body) or not ownerOnline(ownerName) then
        return nil, "the owning player must be online"
    end
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil, "set a base first" end
    local anchor = {x=data.GoblinBaseX,y=data.GoblinBaseY,z=data.GoblinBaseZ}
    if not Support.validPoint(anchor) then return nil, "saved base position is invalid" end
    local scope = Curtains.scopeAt(anchor)
    if not scope then return nil, "saved base house is unavailable" end
    local target, failure = Stockpiles.target(scope, body, request.item)
    if not target then return nil, "tracked container unavailable: "..tostring(failure) end
    local row = rowFor(Stockpiles.scan(scope, body), request.item)
    if not row or row.current == nil then return nil, "assigned container count is unknown" end
    return {anchor=anchor,building_id=scope.id,item=request.item,
        target_id=target.id,owner=ownerName},
        "stockpile run queued; "..tostring(row.shortage).." item(s) short"
end

function Work.update(body, payload, runtime, now)
    if not ownerOnline(payload.owner) then
        return true, false, "owner logged out; carried items remain with Goblin", "INTERRUPTED"
    end
    local target, scope, failure = targetFor(body, payload)
    if not target then
        return true, false, "assigned stockpile unavailable; carried items remain with Goblin",
            failure or "TARGET_CHANGED"
    end
    local row = rowFor(Stockpiles.scan(scope, body), payload.item)
    if not row or row.current == nil then
        return true, false, "assigned stock count is unknown", statusCode(row)
    end
    local inventory = World.inventory(body)
    local item = runtime.cargo
    local cargoPresent = false
    if item then cargoPresent = contains(inventory, item) end
    if cargoPresent == nil then
        return true, false, "Goblin inventory became unreadable", "ENGINE_ERROR"
    end
    if not item or not cargoPresent or protected(body, item) then
        local why
        item, why = carried(body, payload.item)
        if why then return true, false, why, "ENGINE_ERROR" end
        runtime.cargo = item
    end
    if item then
        if not Support.work(body, runtime, target.square, now, 1200, "LOOT",
            "delivering tracked supplies") then return false end
        target, scope, failure = targetFor(body, payload)
        if not target then
            return true, false, "assigned container changed before delivery; cargo retained",
                failure or "TARGET_CHANGED"
        end
        local ok, why = transfer(body, item, target)
        runtime.cargo, runtime.readyAt = nil, nil
        Body.data(body).GoblinAction = ""
        if not ok then
            local code = why == "assigned container is full" and "BLOCKED" or "ENGINE_ERROR"
            return true, false, why, code
        end
        runtime.completed = (runtime.completed or 0) + 1
        local fresh = rowFor(Stockpiles.scan(scope, body), payload.item)
        if not fresh or fresh.current == nil then
            return true, false, "delivery occurred but destination count is uncertain", "ENGINE_ERROR"
        end
        audit(payload, "deposit", item, target.square, row.current, fresh.current)
        if fresh.current >= target.minimum then
            return true, true, "stockpile threshold met with real delivered items", "COMPLETE"
        end
        if runtime.completed >= MAX_DELIVERIES then
            return true, false, "stockpile trip limit reached; remaining shortage "
                ..tostring(fresh.shortage), "TIMEOUT"
        end
        return false
    end
    if row.current >= target.minimum then
        return true, true, "assigned stockpile already meets its threshold", "COMPLETE"
    end
    local source = runtime.source
    if not source then
        source = sourceFor(body, target, payload.item, runtime.skipped,
            runtime.skippedSquares or {}, payload.anchor)
        runtime.source, runtime.sourceAt = source, now
        runtime.readyAt = nil
    end
    if not source then
        if runtime.unreachable and sourceFor(body, target, payload.item, {}, {}, payload.anchor) then
            return true, false, "real "..payload.item.." is nearby but no route reached it",
                "NO_PATH"
        end
        return true, false, "no real "..payload.item.." found within "
            ..SEARCH_RADIUS.." tiles; shortage "..tostring(row.shortage), "MISSING_MATERIAL"
    end
    if not Support.work(body, runtime, source.square, now, 1200, "LOOT",
        "collecting tracked supplies") then
        if now-(runtime.sourceAt or now) > 30000 then
            runtime.skipped[source.item] = true
            runtime.skippedSquares = runtime.skippedSquares or {}
            runtime.skippedSquares[sourceKey(source.square)] = true
            runtime.unreachable = true
            runtime.source, runtime.readyAt = nil, nil
        end
        return false
    end
    target, scope, failure = targetFor(body, payload)
    if not target then
        return true, false, "assigned container changed before pickup",
            failure or "TARGET_CHANGED"
    end
    if source.container == target.container or source.object == target.object then
        return true, false, "source became the assigned destination", "TARGET_CHANGED"
    end
    local roomChecked, room = call(target.container, "hasRoomFor", body, source.item)
    if not roomChecked or room ~= true then
        return true, false, "assigned container filled before pickup", "BLOCKED"
    end
    if World.square(World.point(source.square)) ~= source.square then
        return true, false, "source square unloaded before pickup", "TARGET_UNLOADED"
    end
    local taken, moved = pcall(World.take, body, source)
    runtime.source, runtime.readyAt = nil, nil
    Body.data(body).GoblinAction = ""
    if not taken then
        return true, false, "pickup failed with uncertain item state; do not retry blindly", "ENGINE_ERROR"
    end
    if not moved then
        if contains(inventory, source.item) == true then
            return true, false,
                "pickup moved the item but replication is uncertain; do not retry blindly",
                "ENGINE_ERROR"
        end
        runtime.skipped[source.item] = true
        return false
    end
    if contains(inventory, source.item) ~= true then
        return true, false, "pickup returned success without the exact item", "ENGINE_ERROR"
    end
    audit(payload, "pickup", source.item, source.square, row.current, row.current)
    runtime.cargo = source.item
    return false
end

function Work.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Work
