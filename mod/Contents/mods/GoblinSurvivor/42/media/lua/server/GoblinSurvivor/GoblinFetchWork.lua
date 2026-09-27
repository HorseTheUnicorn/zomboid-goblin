-- FETCH_ITEM: bring the online owner existing items from the saved base.
--
-- The request names one exact installed full type or one storage category and
-- a bounded count. Only real items already inside the base scope are used;
-- a shortage is reported, never filled. Picked-up items are tracked by native
-- ID in the primitive payload ledger so interruption and restart reconcile
-- by identity. Hand-over uses the owner's real inventory; when it is full the
-- items are placed at the owner's feet (the owner asked for them).
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
local Storage = require("GoblinSurvivor/GoblinStorage")
local Transfer = require("GoblinSurvivor/GoblinTransfer")

local Fetch = {}
local call = World.call
local MAX_COUNT = 20
local MAX_SCAN_SQUARES = 4096
local SOURCE_TIMEOUT = 30000
local OWNER_TIMEOUT = 120000

local function playerFor(name)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return nil end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return player end
    end
    return nil
end

local function exactType(fullType)
    if type(fullType) ~= "string" or not string.match(fullType, "^[%w_]+%.[%w_]+$") then return nil end
    local manager = rawget(_G, "ScriptManager")
    local checked, script = call(manager and manager.instance, "FindItem", fullType)
    if not checked or not script then return nil end
    local okName, name = call(script, "getFullName")
    local okObsolete, obsolete = call(script, "getObsolete")
    if okName and name == fullType and okObsolete and obsolete == false then return fullType end
    return nil
end

local function matches(payload, item)
    if payload.item then return World.fullType(item) == payload.item end
    return Storage.category(item) == payload.category
end

local function squarePoint(square)
    local p = World.point(square)
    return { x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z) }
end

local function key(square)
    local p = squarePoint(square)
    return p.x..":"..p.y..":"..p.z
end

local function audit(payload, stage, entry, detail)
    if type(print) ~= "function" then return end
    print("[GoblinSurvivor] FETCH_TRANSFER stage="..stage.." owner="..tostring(payload.owner)
        .." item="..tostring(entry and entry.type).." item_id="..tostring(entry and entry.id)
        .." detail="..tostring(detail or ""))
end

local function carriedEntries(payload)
    local list = {}
    for _, entry in ipairs(payload.ledger or {}) do
        if entry.state == "carried" then list[#list+1] = entry end
    end
    return list
end

local function findSource(body, payload, runtime, scope)
    local here = Body.position(body)
    local best, bestDistance
    local seen, scanned = {}, 0
    for _, room in ipairs(scope.rooms or {}) do
        for x = room.x, room.x2 do for y = room.y, room.y2 do
            local k = x..":"..y..":"..room.z
            if not seen[k] then
                seen[k] = true
                scanned = scanned + 1
                if scanned > MAX_SCAN_SQUARES then return best end
                local square = World.square({ x=x, y=y, z=room.z })
                if square and Curtains.belongsToScope(scope, square) and not runtime.skippedSquares[k]
                    and Policy.access(body, { getSquare=function() return square end }) then
                    local function consider(source)
                        local p = World.point(square)
                        local d = here and ((p.x-here.x)^2 + (p.y-here.y)^2) or 0
                        -- Prefer the category's own storage over a random shelf.
                        if source.preferred then d = d - 10000 end
                        if not best or d < bestDistance then best, bestDistance = source, d end
                    end
                    for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                        local _, container = call(object, "getContainer")
                        local _, metadata = call(object, "getModData")
                        local foreign = type(metadata) == "table" and metadata.GoblinStorageOwner
                            and metadata.GoblinStorageOwner ~= Body.owner(body)
                        if container and not foreign and World.containerAccessible(body, object)
                            and Policy.access(body, object) then
                            local items = {}
                            for _, item in ipairs(World.items(container)) do
                                if matches(payload, item) and not runtime.skipped[item]
                                    and Transfer.movable(body, item) then
                                    items[#items+1] = { item=item }
                                end
                            end
                            if items[1] then
                                consider({ square=square, object=object, container=container, items=items,
                                    preferred=type(metadata) == "table"
                                        and metadata.GoblinStorageCategory == (payload.category
                                            or Storage.category(items[1].item)) })
                            end
                        end
                    end
                    local floor = {}
                    for _, worldObject in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
                        local _, item = call(worldObject, "getItem")
                        if item and matches(payload, item) and not runtime.skipped[item]
                            and Transfer.movable(body, item) then
                            floor[#floor+1] = { item=item, world=worldObject }
                        end
                    end
                    if floor[1] then consider({ square=square, items=floor }) end
                end
            end
        end end
    end
    return best
end

local function reconcile(body, payload)
    local kept, lost = {}, 0
    for _, entry in ipairs(payload.ledger or {}) do
        if entry.state == "carried" or entry.state == "pending" then
            local found = Transfer.findById(World.inventory(body), entry.id)
            if found then
                entry.state = "carried"; kept[#kept+1] = entry
            elseif found == nil then
                lost = lost + 1; kept[#kept+1] = entry
            else
                -- Not carried: either never left the source (pending) or it is
                -- already with the owner/floor. Check the source square.
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
                local player = playerFor(payload.owner)
                local ownerInventory = player and select(2, call(player, "getInventory"))
                if ownerInventory and Transfer.findById(ownerInventory, entry.id) then
                    payload.delivered = (tonumber(payload.delivered) or 0) + 1
                    audit(payload, "reconciled_delivered", entry)
                elseif atSource then
                    audit(payload, "reconciled_at_source", entry)
                else
                    lost = lost + 1
                    audit(payload, "reconciled_missing", entry)
                end
            end
        end
    end
    payload.ledger = kept
    return lost
end

function Fetch.prepare(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true or request.autonomous == true then
        return nil, "fetching requires an explicit order from the online owner"
    end
    local ownerName = select(2, call(owner, "getUsername"))
    if ownerName ~= Body.owner(body) or not playerFor(ownerName) then
        return nil, "the owning player must be online"
    end
    local count = tonumber(request.count) or 1
    if count ~= math.floor(count) or count < 1 or count > MAX_COUNT then
        return nil, "fetch count must be an integer from 1 to "..MAX_COUNT
    end
    local item = exactType(request.item)
    local category = not item and Storage.normalize(request.item or request.category) or nil
    if not item and (not category or category == "INBOX" or category == "OVERFLOW") then
        return nil, "name an exact installed item (Base.Nails) or a storage category (food, medical...)"
    end
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil, "set a base first" end
    local anchor = { x=data.GoblinBaseX, y=data.GoblinBaseY, z=data.GoblinBaseZ }
    if not Support.validPoint(anchor) then return nil, "saved base position is invalid" end
    local scope = Curtains.scopeAt(anchor)
    if not scope then return nil, "saved base house is unavailable" end
    return { anchor=anchor, building_id=scope.id, owner=ownerName, item=item, category=category,
        count=count, delivered=0, ledger={} },
        "fetching "..count.." "..tostring(item or string.lower(category)).." from base"
end

local function handOver(body, payload, runtime, now)
    local carried = carriedEntries(payload)
    if not carried[1] then return nil end
    local player = playerFor(payload.owner)
    if not player then
        return true, false, "owner logged out; "..#carried.." fetched item(s) remain with Goblin", "INTERRUPTED"
    end
    local ownerSquare = select(2, call(player, "getCurrentSquare"))
    if not ownerSquare then return true, false, "owner position unavailable", "TARGET_UNLOADED" end
    runtime.ownerAt = runtime.ownerAt or now
    if not World.approach(body, ownerSquare, now) then
        if now - runtime.ownerAt > OWNER_TIMEOUT then
            return true, false, "could not reach you with "..#carried.." item(s); they stay with Goblin", "NO_PATH"
        end
        return false
    end
    runtime.ownerAt = nil
    for _, entry in ipairs(carried) do
        local item = Transfer.findById(World.inventory(body), entry.id)
        if not item then
            return true, false, "fetched item "..tostring(entry.type).." is no longer carried", "ENGINE_ERROR"
        end
        local ok, code, detail = Transfer.handOver(body, item, player, true)
        if not ok then return true, false, detail or "hand-over failed", code or "ENGINE_ERROR" end
        entry.state = "delivered"
        payload.delivered = (tonumber(payload.delivered) or 0) + 1
        audit(payload, "handover", entry, detail)
    end
    local open = {}
    for _, entry in ipairs(payload.ledger) do if entry.state == "carried" then open[#open+1] = entry end end
    payload.ledger = open
    local label = tostring(payload.item or string.lower(payload.category))
    if payload.delivered >= payload.count then
        return true, true, "brought you "..payload.delivered.." "..label, "COMPLETE"
    end
    return true, false, "brought "..payload.delivered.." of "..payload.count.." "..label
        .."; no more real stock found in base", "MISSING_MATERIAL"
end

function Fetch.update(body, payload, runtime, now)
    runtime.skipped = runtime.skipped or {}
    runtime.skippedSquares = runtime.skippedSquares or {}
    if not playerFor(payload.owner) then
        return true, false, "owner logged out; "..#carriedEntries(payload)
            .." fetched item(s) remain with Goblin", "INTERRUPTED"
    end
    if type(payload.ledger) ~= "table" then payload.ledger = {} end
    if not runtime.reconciled then
        runtime.reconciled = true
        local lost = reconcile(body, payload)
        if lost > 0 then
            return true, false, lost.." fetched item(s) could not be located after interruption", "ENGINE_ERROR"
        end
    end
    local want = payload.count - (tonumber(payload.delivered) or 0) - #carriedEntries(payload)
    if want <= 0 or runtime.exhausted then
        local done, success, detail, code = handOver(body, payload, runtime, now)
        if done == nil then
            local label = tostring(payload.item or string.lower(payload.category))
            if (tonumber(payload.delivered) or 0) >= payload.count then
                return true, true, "brought you "..payload.delivered.." "..label, "COMPLETE"
            end
            if (tonumber(payload.delivered) or 0) > 0 then
                return true, false, "brought "..payload.delivered.." of "..payload.count.." "..label
                    .."; no more real stock found in base", "MISSING_MATERIAL"
            end
            return true, false, "no "..label.." found in the base", "MISSING_MATERIAL"
        end
        return done, success, detail, code
    end
    local scope = Curtains.scopeAt(payload.anchor)
    if not scope or scope.id ~= payload.building_id then
        return true, false, "base house changed or unloaded", "TARGET_UNLOADED"
    end
    local source = runtime.source
    if not source then
        source = findSource(body, payload, runtime, scope)
        if not source then runtime.exhausted = true; return false end
        runtime.source, runtime.sourceAt, runtime.readyAt = source, now, nil
    end
    if not Support.work(body, runtime, source.square, now, 900, "LOOT", "collecting what you asked for") then
        if now - (runtime.sourceAt or now) > SOURCE_TIMEOUT then
            runtime.skippedSquares[key(source.square)] = true
            runtime.source, runtime.readyAt = nil, nil
        end
        return false
    end
    runtime.source, runtime.readyAt = nil, nil
    Body.data(body).GoblinAction = ""
    for _, candidate in ipairs(source.items) do
        if want <= 0 then break end
        local id = Transfer.itemId(candidate.item)
        if not id then
            runtime.skipped[candidate.item] = true
        else
            local entry = { id=id, type=World.fullType(candidate.item), from=squarePoint(source.square),
                state="pending" }
            payload.ledger[#payload.ledger+1] = entry
            local ok, code, detail = Transfer.pickup(body, { square=source.square, object=source.object,
                container=source.container, world=candidate.world, item=candidate.item })
            if ok then
                entry.state = "carried"; want = want - 1
                audit(payload, "pickup", entry)
            else
                table.remove(payload.ledger)
                runtime.skipped[candidate.item] = true
                if code == "ENGINE_ERROR" then return true, false, detail, "ENGINE_ERROR" end
                -- Inventory full: go hand over what is carried.
                if #carriedEntries(payload) > 0 then runtime.exhausted = true; break end
            end
        end
    end
    return false
end

function Fetch.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Fetch
