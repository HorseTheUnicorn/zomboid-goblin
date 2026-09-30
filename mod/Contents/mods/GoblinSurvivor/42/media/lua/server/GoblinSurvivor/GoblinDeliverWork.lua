-- DELIVER: put the Goblin's own carried cargo away in base storage.
--
-- Cargo is selected at prepare time by native item ID (optionally filtered by
-- exact full type or category) and written to the payload ledger, so only
-- those exact instances are delivered. Each item goes to a container of its
-- category, then OVERFLOW, then INBOX. A floor drop inside the base happens
-- only when the owner explicitly allowed it; otherwise undeliverable cargo is
-- kept and reported.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Storage = require("GoblinSurvivor/GoblinStorage")
local Transfer = require("GoblinSurvivor/GoblinTransfer")

local Deliver = {}
local call = World.call
local MAX_ITEMS = 40

local function online(name)
    if type(getOnlinePlayers) ~= "function" then return false end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return false end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return true end
    end
    return false
end

local function audit(payload, stage, entry, detail)
    if type(print) ~= "function" then return end
    print("[GoblinSurvivor] DELIVER_TRANSFER stage="..stage.." owner="..tostring(payload.owner)
        .." item="..tostring(entry and entry.type).." item_id="..tostring(entry and entry.id)
        .." destination="..tostring(entry and entry.dest).." detail="..tostring(detail or ""))
end

local function targetFor(body, live, entry, item, full)
    local order = Storage.destinations(live, entry.category or "MISC")
    for _, target in ipairs(live) do
        if target.category == "INBOX" then order[#order+1] = target end
    end
    for _, target in ipairs(order) do
        local checked, room = call(target.container, "hasRoomFor", body, item)
        if full and full[target.id] then checked = false end
        if checked and room == true then return target end
    end
    return nil
end

function Deliver.prepare(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true or request.autonomous == true then
        return nil, "delivery requires an explicit order from the online owner"
    end
    local ownerName = select(2, call(owner, "getUsername"))
    if ownerName ~= Body.owner(body) or not online(ownerName) then
        return nil, "the owning player must be online"
    end
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil, "set a base first" end
    local anchor = { x=data.GoblinBaseX, y=data.GoblinBaseY, z=data.GoblinBaseZ }
    local scope = Support.validPoint(anchor) and Curtains.scopeAt(anchor)
    if not scope then return nil, "saved base house is unavailable" end
    local filterType = type(request.item) == "string" and string.find(request.item, ".", 1, true)
        and request.item or nil
    local filterCategory = not filterType and request.item and Storage.normalize(request.item) or nil
    if request.item and not filterType and not filterCategory then
        return nil, "name an exact item or a storage category to deliver"
    end
    local ledger = {}
    local selected
    if type(request.selected_ids) == "table" then
        selected = {}
        for _, id in ipairs(request.selected_ids) do selected[id] = true end
    end
    for _, item in ipairs(World.items(World.inventory(body))) do
        if #ledger >= MAX_ITEMS then break end
        local id = Transfer.itemId(item)
        local kind = World.fullType(item)
        local category = Storage.category(item)
        if id and Transfer.movable(body, item)
            and (not selected or selected[id])
            and (not filterType or kind == filterType)
            and (not filterCategory or category == filterCategory) then
            ledger[#ledger+1] = { id=id, type=kind, category=category or "MISC", state="carried" }
        end
    end
    if not ledger[1] then return nil, "I am not carrying anything that matches" end
    return { anchor=anchor, building_id=scope.id, owner=ownerName, allow_floor=request.allow_floor == true,
        delivered=0, floor=0, ledger=ledger },
        "delivering "..#ledger.." carried item(s) to base storage"
end

function Deliver.update(body, payload, runtime, now)
    if not online(payload.owner) then
        return true, false, "owner logged out; cargo stays with Goblin", "INTERRUPTED"
    end
    local scope = Curtains.scopeAt(payload.anchor)
    if not scope or scope.id ~= payload.building_id then
        return true, false, "base house changed or unloaded; cargo kept", "TARGET_UNLOADED"
    end
    local live = Storage.assignments(body, scope)
    if not live then return true, false, "storage assignments unavailable", "TARGET_UNLOADED" end
    local open, missing = {}, 0
    for _, entry in ipairs(payload.ledger or {}) do
        if entry.state == "carried" then
            local item = Transfer.findById(World.inventory(body), entry.id)
            if item == nil then return true, false, "Goblin inventory became unreadable", "ENGINE_ERROR" end
            if item then open[#open+1] = entry
            else
                -- A restart can land after deposit but before the ledger save;
                -- look for the exact ID in storage before calling it missing.
                local stored = false
                for _, target in ipairs(live) do
                    if Transfer.findById(target.container, entry.id) then stored = true; break end
                end
                if stored then
                    payload.delivered = (tonumber(payload.delivered) or 0) + 1
                    audit(payload, "reconciled_delivered", entry)
                else
                    missing = missing + 1
                    audit(payload, "reconciled_missing", entry)
                end
            end
        end
    end
    payload.ledger = open
    local function summary()
        local text = "delivered "..tostring(payload.delivered or 0).." item(s)"
        if (tonumber(payload.floor) or 0) > 0 then text = text.." ("..payload.floor.." on the base floor)" end
        if missing > 0 then text = text.."; "..missing.." item(s) were no longer carried" end
        return text
    end
    local entry = open[1]
    if not entry then return true, missing == 0, summary(), missing == 0 and "COMPLETE" or "TARGET_CHANGED" end
    local item = Transfer.findById(World.inventory(body), entry.id)
    runtime.full = runtime.full or {}
    local target = targetFor(body, live, entry, item, runtime.full)
    if not target then
        if not payload.allow_floor then
            return true, false, summary().."; no storage room for "..#open.." item(s), kept by Goblin", "BLOCKED"
        end
        local square = World.square(payload.anchor)
        if not Support.work(body, runtime, square, now, 800, "LOOT", "setting supplies down at base") then
            return false
        end
        runtime.readyAt = nil
        local ok, code, detail = Transfer.drop(body, item, square)
        if not ok then return true, false, detail, code end
        entry.state = "delivered"; entry.dest = "floor"
        payload.delivered = (tonumber(payload.delivered) or 0) + 1
        payload.floor = (tonumber(payload.floor) or 0) + 1
        audit(payload, "floor", entry)
        return false
    end
    if not Support.work(body, runtime, target.square, now, 900, "LOOT", "putting cargo away") then
        return false
    end
    runtime.readyAt = nil
    Body.data(body).GoblinAction = ""
    for _, other in ipairs(open) do
        local carried = Transfer.findById(World.inventory(body), other.id)
        local fits = carried and (other.category == target.category or target.category == "OVERFLOW"
            or target.category == "INBOX" or other == entry)
        if fits then
            other.dest = target.id
            local ok, code, detail = Transfer.deposit(body, carried, target.container)
            if ok then
                other.state = "delivered"
                payload.delivered = (tonumber(payload.delivered) or 0) + 1
                audit(payload, "deposit", other)
            elseif code ~= "BLOCKED" then
                return true, false, detail or "delivery failed", code or "ENGINE_ERROR"
            end
        end
    end
    if entry.state == "carried" then runtime.full[target.id] = true end
    return false
end

function Deliver.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Deliver
