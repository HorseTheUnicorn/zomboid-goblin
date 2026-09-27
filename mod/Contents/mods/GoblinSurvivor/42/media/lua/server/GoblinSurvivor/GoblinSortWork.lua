-- SORT_STORAGE: explicit owner-ordered sorting of existing base items into
-- the owner's semantic storage containers.
--
-- Sources (default): INBOX containers and items sitting in a container
-- assigned to a different category. "sort all" additionally drains unassigned
-- containers (never cold storage) and loose floor items inside the base.
-- Each moved item is recorded in a primitive per-item ledger (native item ID,
-- category, destination ID, source square) so a restart or interruption can
-- reconcile source/carried/destination state without duplicating or minting.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
local Storage = require("GoblinSurvivor/GoblinStorage")
local Transfer = require("GoblinSurvivor/GoblinTransfer")

local Sort = {}
local call = World.call
local MAX_BATCH = 6
local MAX_ITEMS = 60
local MAX_SCAN_SQUARES = 4096
local SOURCE_TIMEOUT = 30000
local COLD = { fridge=true, freezer=true }

local function online(name)
    if type(getOnlinePlayers) ~= "function" then return false end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return false end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return true end
    end
    return false
end

local function key(square)
    local p = World.point(square)
    return math.floor(p.x)..":"..math.floor(p.y)..":"..math.floor(p.z)
end

local function squarePoint(square)
    local p = World.point(square)
    return { x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z) }
end

local function audit(payload, stage, entry, detail)
    if type(print) ~= "function" then return end
    print("[GoblinSurvivor] SORT_TRANSFER stage="..stage.." owner="..tostring(payload.owner)
        .." item="..tostring(entry and entry.type).." item_id="..tostring(entry and entry.id)
        .." category="..tostring(entry and entry.category).." destination="..tostring(entry and entry.dest)
        .." detail="..tostring(detail or ""))
end

local function scopeFor(payload)
    local scope = Curtains.scopeAt(payload.anchor)
    if not scope or scope.id ~= payload.building_id then return nil end
    return scope
end

-- Iterate loaded squares of the exact base scope (bounded).
local function eachScopeSquare(scope, visit)
    local seen, scanned = {}, 0
    for _, room in ipairs(scope.rooms or {}) do
        for x = room.x, room.x2 do for y = room.y, room.y2 do
            local k = x..":"..y..":"..room.z
            if not seen[k] then
                seen[k] = true
                scanned = scanned + 1
                if scanned > MAX_SCAN_SQUARES then return false end
                local square = World.square({ x=x, y=y, z=room.z })
                if square and Curtains.belongsToScope(scope, square) then
                    if visit(square) == false then return true end
                end
            end
        end end
    end
    return true
end

local function containerType(container)
    local ok, kind = call(container, "getType")
    return ok and type(kind) == "string" and string.lower(kind) or ""
end

-- Returns destination target with room for item, or nil.
local function destinationFor(body, live, category, item, preferredId, full)
    full = full or {}
    local preferred = preferredId and not full[preferredId] and Storage.byId(live, preferredId)
    if preferred and (preferred.category == category or preferred.category == "OVERFLOW") then
        local checked, room = call(preferred.container, "hasRoomFor", body, item)
        if checked and room == true then return preferred end
    end
    for _, target in ipairs(Storage.destinations(live, category)) do
        if not full[target.id] then
            local checked, room = call(target.container, "hasRoomFor", body, item)
            if checked and room == true then return target end
        end
    end
    return nil
end

local function hasDestination(live, category)
    return #Storage.destinations(live, category) > 0
end

-- Collect sortable candidate items grouped per source (container or floor).
local function findSource(body, payload, runtime, live, scope)
    local assigned = {}
    for _, target in ipairs(live) do assigned[target.object] = target end
    local here = Body.position(body)
    local best, bestDistance
    local function consider(source, distanceSquare)
        local p = World.point(distanceSquare)
        local d = here and ((p.x-here.x)^2 + (p.y-here.y)^2) or 0
        if not best or d < bestDistance then best, bestDistance = source, d end
    end
    local complete = eachScopeSquare(scope, function(square)
        if runtime.skippedSquares[key(square)] then return true end
        if not Policy.access(body, { getSquare=function() return square end }) then return true end
        for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
            local _, container = call(object, "getContainer")
            if container and World.containerAccessible(body, object) and Policy.access(body, object) then
                local own = assigned[object]
                local _, metadata = call(object, "getModData")
                local foreign = type(metadata) == "table" and metadata.GoblinStorageOwner
                    and metadata.GoblinStorageOwner ~= Body.owner(body)
                local drain = not foreign and (
                    (own and own.category == "INBOX")
                    or (own and own.category ~= "OVERFLOW")
                    or (not own and payload.all == true))
                if drain then
                    local cold = COLD[containerType(container)] == true
                    local items = {}
                    for _, item in ipairs(World.items(container)) do
                        local category = Storage.category(item)
                        local misplaced = category and (not own or own.category == "INBOX"
                            or own.category ~= category)
                        if misplaced and not (cold and category == "FOOD")
                            and not runtime.skipped[item] and Transfer.movable(body, item)
                            and hasDestination(live, category)
                            and not (own and own.category == "OVERFLOW") then
                            items[#items+1] = { item=item, category=category }
                        end
                    end
                    if items[1] then
                        consider({ square=square, object=object, container=container, items=items }, square)
                    end
                end
            end
        end
        if payload.all == true then
            local items = {}
            for _, worldObject in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
                local _, item = call(worldObject, "getItem")
                local category = item and Storage.category(item)
                if category and not runtime.skipped[item] and Transfer.movable(body, item)
                    and hasDestination(live, category) then
                    items[#items+1] = { item=item, category=category, world=worldObject }
                end
            end
            if items[1] then consider({ square=square, floor=true, items=items }, square) end
        end
        return true
    end)
    return best, complete
end

local function ledgerCount(payload, state)
    local n = 0
    for _, entry in ipairs(payload.ledger or {}) do if not state or entry.state == state then n = n + 1 end end
    return n
end

local function finish(payload, success, code, extra)
    local text = string.format("sorted %d item(s)", tonumber(payload.moved) or 0)
    if (tonumber(payload.returned) or 0) > 0 then
        text = text..string.format("; %d returned to their source (no room)", payload.returned)
    end
    if extra then text = text.."; "..extra end
    return true, success, text, code
end

-- Restart/interruption reconciliation of the persisted per-item ledger.
local function reconcile(body, payload, live, scope)
    local kept, uncertain = {}, 0
    for _, entry in ipairs(payload.ledger or {}) do
        local where, item = Transfer.locate(body, entry.id, nil, nil)
        if where == "carried" then
            entry.state = "carried"; kept[#kept+1] = entry
        elseif where == "unknown" then
            uncertain = uncertain + 1; kept[#kept+1] = entry
        else
            local found = false
            for _, target in ipairs(live) do
                if Transfer.findById(target.container, entry.id) then
                    found = true
                    if target.id == entry.dest or target.category == entry.category
                        or target.category == "OVERFLOW" then
                        payload.moved = (tonumber(payload.moved) or 0) + 1
                        audit(payload, "reconciled_delivered", entry)
                    else
                        audit(payload, "reconciled_unmoved", entry)
                    end
                    break
                end
            end
            if not found then
                local square = World.square(entry.from or {})
                local atSource = false
                if square then
                    for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                        local _, container = call(object, "getContainer")
                        if container and Transfer.findById(container, entry.id) then atSource = true end
                    end
                    for _, worldObject in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
                        local _, worldItem = call(worldObject, "getItem")
                        if worldItem and Transfer.itemId(worldItem) == entry.id then atSource = true end
                    end
                end
                if atSource then
                    audit(payload, "reconciled_at_source", entry)
                else
                    uncertain = uncertain + 1
                    audit(payload, "reconciled_missing", entry)
                end
            end
        end
    end
    payload.ledger = kept
    return uncertain
end

function Sort.prepare(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true or request.autonomous == true then
        return nil, "sorting requires an explicit order from the online owner"
    end
    local ownerName = select(2, call(owner, "getUsername"))
    if ownerName ~= Body.owner(body) or not online(ownerName) then
        return nil, "the owning player must be online"
    end
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil, "set a base first" end
    local anchor = { x=data.GoblinBaseX, y=data.GoblinBaseY, z=data.GoblinBaseZ }
    if not Support.validPoint(anchor) then return nil, "saved base position is invalid" end
    local scope = Curtains.scopeAt(anchor)
    if not scope then return nil, "saved base house is unavailable" end
    local live = Storage.assignments(body, scope)
    if not live then return nil, "storage assignments are unavailable" end
    local categories = 0
    for _, target in ipairs(live) do
        if target.category ~= "INBOX" then categories = categories + 1 end
    end
    if categories == 0 then
        return nil, "assign at least one storage category first (/goblin storage FOOD beside a container)"
    end
    return { anchor=anchor, building_id=scope.id, owner=ownerName, all=request.all == true,
        moved=0, returned=0, ledger={} },
        request.all == true and "sorting every loose item in the base" or "sorting the inbox and misplaced items"
end

local function deliverCarried(body, payload, runtime, now, live)
    local open = {}
    for _, candidate in ipairs(payload.ledger) do
        if candidate.state == "carried" or candidate.state == "pending" then open[#open+1] = candidate end
    end
    payload.ledger = open
    local entry
    for _, candidate in ipairs(payload.ledger) do
        if candidate.state == "carried" then entry = candidate; break end
    end
    if not entry then return nil end
    local item = Transfer.findById(World.inventory(body), entry.id)
    if item == nil then return true, false, "Goblin inventory became unreadable", "ENGINE_ERROR" end
    if item == false then
        return true, false, "carried item "..tostring(entry.type).." vanished before delivery", "ENGINE_ERROR"
    end
    runtime.full = runtime.full or {}
    local target = destinationFor(body, live, entry.category, item, entry.dest, runtime.full)
    if not target then
        -- Full-container fallback: same category -> OVERFLOW -> original source.
        entry.dest = nil
        local square = World.square(entry.from or {})
        if not square then
            return finish(payload, false, "BLOCKED", "no room for "..entry.category
                .."; "..ledgerCount(payload, "carried").." item(s) kept by Goblin")
        end
        if not Support.work(body, runtime, square, now, 800, "LOOT", "returning an item with no storage room") then
            return false
        end
        local returned
        for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
            local _, container = call(object, "getContainer")
            if container and World.containerAccessible(body, object) and Policy.access(body, object) then
                local ok = Transfer.deposit(body, item, container)
                if ok then returned = true; break end
            end
        end
        runtime.readyAt = nil
        if not returned then
            return finish(payload, false, "BLOCKED", "no room for "..entry.category
                .." and the source is full; "..ledgerCount(payload, "carried").." item(s) kept by Goblin")
        end
        entry.state = "returned"
        payload.returned = (tonumber(payload.returned) or 0) + 1
        audit(payload, "returned", entry)
        runtime.noRoom = runtime.noRoom or {}
        runtime.noRoom[entry.category] = true
        return false
    end
    entry.dest = target.id
    if not Support.work(body, runtime, target.square, now, 900, "LOOT", "putting supplies away") then
        return false
    end
    -- Revalidate the live destination after travel.
    local fresh = Storage.resolve(body, scopeFor(payload) or {}, {
        id=target.id, category=target.category, x=squarePoint(target.square).x,
        y=squarePoint(target.square).y, z=squarePoint(target.square).z, building_id=payload.building_id })
    if not fresh or fresh.container ~= target.container then
        runtime.readyAt = nil
        return true, false, "storage container changed before delivery; items kept by Goblin", "TARGET_CHANGED"
    end
    -- Deposit every carried item for this destination in one visit.
    for _, other in ipairs(payload.ledger) do
        if other.state == "carried" and (other == entry or other.dest == target.id
            or (other.category == target.category and not other.dest)) then
            local carriedItem = Transfer.findById(World.inventory(body), other.id)
            if carriedItem then
                local ok, code, detail = Transfer.deposit(body, carriedItem, target.container)
                if ok then
                    other.state = "delivered"
                    payload.moved = (tonumber(payload.moved) or 0) + 1
                    audit(payload, "deposit", other)
                elseif code == "BLOCKED" then
                    other.dest = nil
                    runtime.full[target.id] = true
                    audit(payload, "deposit_blocked", other, detail)
                else
                    runtime.readyAt = nil
                    return true, false, detail or "delivery failed", code or "ENGINE_ERROR"
                end
            end
        end
    end
    runtime.readyAt = nil
    Body.data(body).GoblinAction = ""
    local remaining = {}
    for _, other in ipairs(payload.ledger) do
        if other.state == "carried" then remaining[#remaining+1] = other end
    end
    payload.ledger = remaining
    return false
end

function Sort.update(body, payload, runtime, now)
    runtime.skipped = runtime.skipped or {}
    runtime.skippedSquares = runtime.skippedSquares or {}
    if not online(payload.owner) then
        return true, false, "owner logged out; "..ledgerCount(payload, "carried")
            .." carried item(s) remain with Goblin", "INTERRUPTED"
    end
    local scope = scopeFor(payload)
    if not scope then return true, false, "base house changed or unloaded", "TARGET_UNLOADED" end
    local live = Storage.assignments(body, scope)
    if not live then return true, false, "storage assignments unavailable", "TARGET_UNLOADED" end
    if type(payload.ledger) ~= "table" then payload.ledger = {} end
    if not runtime.reconciled then
        runtime.reconciled = true
        local uncertain = reconcile(body, payload, live, scope)
        if uncertain > 0 then
            return true, false, uncertain.." ledger item(s) could not be located after interruption; "
                .."sorting stopped to avoid duplication", "ENGINE_ERROR"
        end
    end
    local done, success, detail, code = deliverCarried(body, payload, runtime, now, live)
    if done ~= nil then return done, success, detail, code end
    if (tonumber(payload.moved) or 0) >= MAX_ITEMS then
        return finish(payload, true, "COMPLETE", "trip limit reached; order sorting again for more")
    end
    local source = runtime.source
    if not source then
        local complete
        source, complete = findSource(body, payload, runtime, live, scope)
        if not source then
            if complete == false then
                return finish(payload, false, "BLOCKED", "base is larger than the sorting scan limit")
            end
            if scope.partiallyStreamed then
                return finish(payload, true, "COMPLETE", "loaded rooms only; some floors were not loaded")
            end
            return finish(payload, true, "COMPLETE")
        end
        runtime.source, runtime.sourceAt, runtime.readyAt = source, now, nil
    end
    if not Support.work(body, runtime, source.square, now, 900, "LOOT", "collecting items to sort") then
        if now - (runtime.sourceAt or now) > SOURCE_TIMEOUT then
            runtime.skippedSquares[key(source.square)] = true
            runtime.source, runtime.readyAt = nil, nil
        end
        return false
    end
    runtime.source, runtime.readyAt = nil, nil
    Body.data(body).GoblinAction = ""
    local taken = 0
    for _, candidate in ipairs(source.items) do
        if taken >= MAX_BATCH or (tonumber(payload.moved) or 0) + ledgerCount(payload, "carried") >= MAX_ITEMS then
            break
        end
        local target = destinationFor(body, live, candidate.category, candidate.item, nil, runtime.full)
        if target and not (runtime.noRoom and runtime.noRoom[candidate.category]) then
            local id = Transfer.itemId(candidate.item)
            if not id then
                runtime.skipped[candidate.item] = true
            else
                local entry = { id=id, type=World.fullType(candidate.item), category=candidate.category,
                    dest=target.id, from=squarePoint(source.square), state="pending" }
                -- Persist intent before the native move so a crash mid-transfer
                -- is reconciled by identity instead of forgotten.
                payload.ledger[#payload.ledger+1] = entry
                local ok, code, detail = Transfer.pickup(body, { square=source.square, object=source.object,
                    container=source.container, world=candidate.world, item=candidate.item })
                if ok then
                    entry.state = "carried"
                    taken = taken + 1
                    audit(payload, "pickup", entry)
                else
                    table.remove(payload.ledger)
                    runtime.skipped[candidate.item] = true
                    if code == "ENGINE_ERROR" then
                        return true, false, detail or "pickup failed", "ENGINE_ERROR"
                    end
                    -- Goblin inventory full: deliver what is carried first.
                    if taken > 0 then break end
                end
            end
        else
            runtime.skipped[candidate.item] = true
        end
    end
    return false
end

function Sort.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Sort
