-- Milestone 6 vehicle service: inspect, refuel, tires, and part install/removal.
--
-- Vanilla's install/uninstall tests (Vehicles.InstallTest.Default) resolve
-- tools through getPlayerNum()/inventory UI panes, which a managed IsoZombie
-- does not have. This module re-evaluates the same script tables server-side
-- against the Goblin's own inventory: requireInstalled/requireUninstalled,
-- tool items/tags and requireEmpty. Recipe/profession/trait gates and the
-- mechanic key rule always pass: Goblin knows every skill and opens any lock. Mutations then follow the vanilla complete()
-- bodies: skill roll from calculateInstallationSuccess, setInventoryItem,
-- install/uninstall complete callbacks, transmitPartItem/ModData.
-- Fuel comes from carried or conjured petrol cans, or a pump with piped fuel.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Tools = require("GoblinSurvivor/GoblinTools")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Transfer = require("GoblinSurvivor/GoblinTransfer")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")

local Service = {}
local call = World.call
local SELECT_RADIUS2 = 150 * 150 -- Goblin range (Config.goblinRange)
local MOVED_RADIUS2 = 64
local TAG_TOOLS = {
    ["base:wrench"] = { "Base.Wrench", "Base.PipeWrench" },
    ["base:screwdriver"] = { "Base.Screwdriver" },
    ["base:lugwrench"] = { "Base.LugWrench" },
    ["base:jack"] = { "Base.Jack" },
}
local TIRES = { "TireFrontLeft", "TireFrontRight", "TireRearLeft", "TireRearRight" }

-- ---------------------------------------------------------------- helpers

local function online(name)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return nil end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return player end
    end
    return nil
end

local function num(object, method, ...)
    local ok, value = call(object, method, ...)
    if ok and type(value) == "number" and value == value then return value end
    return nil
end

local function position(vehicle)
    local x, y, z = num(vehicle, "getX"), num(vehicle, "getY"), num(vehicle, "getZ")
    if x and y and z then return { x=x, y=y, z=z } end
    return Body.position(vehicle)
end

local function identity(vehicle)
    return { id=num(vehicle, "getId"), sql=num(vehicle, "getSqlId") }
end

local function vehicles()
    local cell = type(getCell) == "function" and getCell() or nil
    return World.values(select(2, call(cell, "getVehicles")))
end

function Service.nearestVehicle(point)
    local chosen, best
    for _, vehicle in ipairs(vehicles()) do
        local p = position(vehicle)
        if p and math.floor(p.z) == math.floor(point.z) then
            local d = (p.x-point.x)^2 + (p.y-point.y)^2
            if d <= SELECT_RADIUS2 and (not best or d < best) then chosen, best = vehicle, d end
        end
    end
    return chosen
end

-- Session IDs change across restarts; the persistent SQL ID plus the saved
-- anchor re-identifies the same vehicle without adopting a neighbour.
function Service.resolve(payload)
    local vehicle = type(getVehicleById) == "function" and payload.vehicle_id
        and select(2, pcall(getVehicleById, payload.vehicle_id)) or nil
    if vehicle and payload.vehicle_sql and num(vehicle, "getSqlId") ~= payload.vehicle_sql then vehicle = nil end
    if not vehicle and payload.vehicle_sql then
        for _, candidate in ipairs(vehicles()) do
            if num(candidate, "getSqlId") == payload.vehicle_sql then vehicle = candidate; break end
        end
    end
    if not vehicle then return nil, "vehicle unloaded or removed", "TARGET_UNLOADED" end
    local p = position(vehicle)
    if not p or math.floor(p.z) ~= math.floor(payload.anchor.z)
        or (p.x-payload.anchor.x)^2 + (p.y-payload.anchor.y)^2 > MOVED_RADIUS2 then
        return nil, "the marked vehicle moved; issue a new order", "TARGET_CHANGED"
    end
    return vehicle
end

function Service.parked(vehicle, allowOccupants)
    local speed = num(vehicle, "getCurrentSpeedKmHour")
    local running = select(2, call(vehicle, "isEngineRunning"))
    if not speed or running == nil then return false, "vehicle state could not be checked", "ENGINE_ERROR" end
    if math.abs(speed) > 0.1 or running == true then
        return false, "park the vehicle and switch its engine off first", "TARGET_CHANGED"
    end
    if not allowOccupants then
        local seats = num(vehicle, "getMaxPassengers") or 0
        for seat = 0, seats - 1 do
            if select(2, call(vehicle, "getCharacter", seat)) then
                return false, "everyone must leave the vehicle first", "BLOCKED"
            end
        end
    end
    return true
end

local function part(vehicle, id)
    local ok, value = call(vehicle, "getPartById", id)
    if ok and value then return value end
    -- Qwen sends lower-case part ids ("tirefrontleft"); match case-insensitively.
    if type(id) ~= "string" then return nil end
    local wanted = string.lower(id)
    local count = num(vehicle, "getPartCount") or 0
    for index = 0, math.min(count, 128) - 1 do
        local candidate = select(2, call(vehicle, "getPartByIndex", index))
        local cid = candidate and select(2, call(candidate, "getId"))
        if type(cid) == "string" and string.lower(cid) == wanted then return candidate end
    end
    return nil
end

local function installed(p) return p and select(2, call(p, "getInventoryItem")) or nil end

local function splitList(text)
    local out = {}
    if type(text) ~= "string" then return out end
    for piece in string.gmatch(text, "[^;]+") do out[#out+1] = piece end
    return out
end

local function script(p, name)
    local ok, tbl = call(p, "getTable", name)
    if ok and type(tbl) == "table" then return tbl end
    return nil
end

local function empty(t)
    for _ in pairs(t) do return false end
    return true
end

local function itemTypes(p)
    local ok, list = call(p, "getItemType")
    local out = {}
    if not ok or not list then return out end
    for _, value in ipairs(World.values(list)) do out[tostring(value)] = true end
    return out
end

local function hasTag(item, tag)
    local lookup = rawget(_G, "ItemTag")
    local resource = rawget(_G, "ResourceLocation")
    if lookup and resource and type(lookup.get) == "function" and type(resource.of) == "function" then
        local ok, resolved = pcall(function() return lookup.get(resource.of(tag)) end)
        if ok and resolved then
            local checked, present = call(item, "hasTag", resolved)
            if checked then return present == true end
        end
    end
    return false
end

-- Resolve one install/uninstall "items" entry to a carried, unbroken tool.
local function toolFor(body, entry)
    if type(entry) ~= "table" then return nil end
    local candidates = {}
    if type(entry.type) == "string" then candidates[#candidates+1] = entry.type end
    for _, tag in ipairs(splitList(entry.tags)) do
        for _, kind in ipairs(TAG_TOOLS[tag] or {}) do candidates[#candidates+1] = kind end
    end
    for _, kind in ipairs(candidates) do Tools.ensure(body, kind) end
    for _, item in ipairs(World.items(World.inventory(body))) do
        local kind = World.fullType(item)
        local condition = num(item, "getCondition")
        if condition == nil or condition > 0 then
            for _, wanted in ipairs(candidates) do
                if kind == wanted then return item end
            end
            for _, tag in ipairs(splitList(entry.tags)) do
                if hasTag(item, tag) then return item end
            end
        end
    end
    return nil
end

local function perkLevel(body, name)
    local perks = rawget(_G, "Perks")
    if not perks or type(perks.FromString) ~= "function" then return 0 end
    local ok, perk = pcall(perks.FromString, name)
    if not ok or not perk then return 0 end
    return num(body, "getPerkLevel", perk) or 0
end

-- Vanilla VehicleUtils.calculateInstallationSuccess, evaluated for the Goblin.
function Service.chances(body, skills)
    local success, failure = 100, 0
    for _, perk in ipairs(splitList(skills)) do
        local name, level = string.match(perk, "^([^:]+):(%d+)$")
        level = tonumber(level)
        if name and level then
            local have = perkLevel(body, name)
            if have < level then
                success = success - (20 + (level - have) * 15)
                failure = failure + (20 + (level - have) * 15)
            end
        end
    end
    return math.min(math.max(success, 0), 100), math.min(math.max(failure, 0), 100)
end

-- Goblin opens any lock himself (locked hoods and doors included), so the
-- vanilla mechanic-key rule never blocks him.
local function keyMissing() return false end

-- Server-side equivalent of Vehicles.InstallTest/UninstallTest.Default.
function Service.eligible(body, vehicle, p, mode, item)
    local tbl = script(p, mode)
    if not tbl then return nil, "this part cannot be "..(mode == "install" and "installed" or "removed"), "UNSUPPORTED" end
    local present = installed(p)
    if mode == "install" and present then return nil, "a part is already installed there", "BLOCKED" end
    if mode == "uninstall" and not present then return nil, "nothing is installed there", "NO_TARGET" end
    local types = itemTypes(p)
    if empty(types) then return nil, "this slot has no installable item types", "UNSUPPORTED" end
    if mode == "install" and item and not types[World.fullType(item)] then
        return nil, "that item does not fit this slot", "TARGET_CHANGED"
    end
    for _, required in ipairs(splitList(tbl.requireInstalled)) do
        if not installed(part(vehicle, required)) then
            return nil, required.." must be installed first", "BLOCKED"
        end
    end
    if tbl.requireUninstalled and installed(part(vehicle, tbl.requireUninstalled)) then
        return nil, tostring(tbl.requireUninstalled).." must be removed first", "BLOCKED"
    end
    -- Goblin is a master mechanic: every skill at 10 and every recipe,
    -- profession and trait gate (Basic/Advanced Mechanics, Mechanics
    -- profession) counts as met.
    if mode == "uninstall" and tbl.requireEmpty then
        local amount = num(p, "getContainerContentAmount") or 0
        local container = select(2, call(p, "getItemContainer"))
        local empty = container and select(2, call(container, "isEmpty"))
        if amount > 0.001 or empty == false then return nil, "empty that part first", "BLOCKED" end
        local seat = num(p, "getContainerSeatNumber") or -1
        if seat ~= -1 and select(2, call(vehicle, "isSeatOccupied", seat)) == true then
            return nil, "that seat is occupied", "BLOCKED"
        end
    end
    local tools = {}
    for _, entry in pairs(type(tbl.items) == "table" and tbl.items or {}) do
        local tool = toolFor(body, entry)
        if not tool then
            return nil, "missing tool "..tostring(entry.type or entry.tags), "MISSING_TOOL"
        end
        tools[#tools+1] = { item=tool, equip=entry.equip }
    end
    if keyMissing(body, vehicle, p) then
        return nil, "the vehicle is locked; unlock it or give Goblin the key first", "LOCKED"
    end
    return { tbl=tbl, tools=tools }
end

local function equip(body, tools)
    for _, tool in ipairs(tools) do
        if tool.equip == "primary" then call(body, "setPrimaryHandItem", tool.item)
        elseif tool.equip == "secondary" then call(body, "setSecondaryHandItem", tool.item) end
    end
end

local function workSquare(vehicle, p)
    local area = select(2, call(p, "getArea"))
    return area and select(2, call(vehicle, "getSquareForArea", area)) or nil, area
end

local function atArea(body, vehicle, area)
    local ok, inside = call(vehicle, "isInArea", area, body)
    return ok and inside == true
end

local function duration(body, tbl)
    local time = tonumber(tbl and tbl.time) or 50
    local level = perkLevel(body, "Mechanics")
    time = time - level * (time / 15)
    return math.max(2000, math.min(20000, time * 16.67))
end

local function roll()
    return type(ZombRand) == "function" and ZombRand(100) or 0
end

local function callLua(name, ...)
    if type(name) ~= "string" then return true end
    local utils = rawget(_G, "VehicleUtils")
    if utils and type(utils.callLua) == "function" then
        return pcall(utils.callLua, name, ...)
    end
    return false
end

-- Open the engine cover when a part's install table names one ("door").
local function openCover(vehicle, tbl, runtime)
    if not tbl or type(tbl.door) ~= "string" then return true end
    local cover = part(vehicle, tbl.door)
    local door = cover and select(2, call(cover, "getDoor"))
    if not door or not installed(cover) then return true end
    if select(2, call(door, "isOpen")) == true then return true end
    if select(2, call(door, "isLocked")) == true then
        return false, "the "..tbl.door.." is locked"
    end
    call(door, "setOpen", true)
    call(vehicle, "transmitPartDoor", cover)
    runtime.coverOpened = cover
    return true
end

local function closeCover(vehicle, runtime)
    local cover = runtime.coverOpened
    runtime.coverOpened = nil
    local door = cover and select(2, call(cover, "getDoor"))
    if door then
        call(door, "setOpen", false)
        call(vehicle, "transmitPartDoor", cover)
    end
end

-- ------------------------------------------------------------- part work

-- Returns true when the part now holds item; false on a failed roll.
function Service.installPart(body, vehicle, p, item, plan)
    local success, failure = Service.chances(body, plan.tbl.skills)
    if roll() >= success then
        if roll() < failure then
            local condition = num(item, "getCondition")
            if condition then
                local loss = type(ZombRand) == "function" and ZombRand(5, 10) or 5
                call(item, "setCondition", math.max(0, condition - loss))
            end
        end
        return false, "skill"
    end
    if not Transfer.detach(body, item) then return nil, "could not detach the part item" end
    call(item, "setJobDelta", 0)
    local ok = call(p, "setInventoryItem", item, perkLevel(body, "Mechanics"))
    if not ok or installed(p) ~= item then
        local back = call(World.inventory(body), "AddItem", item)
        if not back or World.containsExact(World.inventory(body), item) ~= true then
            return nil, "install failed and the part item could not be recovered"
        end
        return nil, "the vehicle rejected the part; it stays with Goblin"
    end
    callLua(plan.tbl.complete, vehicle, p)
    call(vehicle, "transmitPartItem", p)
    return true
end

-- Returns the removed item on success, false on a failed roll.
function Service.uninstallPart(body, vehicle, p, plan)
    local item = installed(p)
    if not item then return nil, "part already removed" end
    local success, failure = Service.chances(body, plan.tbl.skills)
    if roll() >= success then
        if type(ZombRand) == "function" and ZombRand(math.max(1, failure)) < 100 then
            local condition = num(p, "getCondition")
            if condition then
                call(p, "setCondition", math.max(0, condition - ZombRand(5, 10)))
                call(vehicle, "transmitPartCondition", p)
            end
        end
        return false, "skill"
    end
    call(item, "setItemCapacity", num(p, "getContainerContentAmount") or 0)
    local ok = call(p, "setInventoryItem", nil)
    if not ok or installed(p) ~= nil then return nil, "the vehicle kept the part" end
    callLua(plan.tbl.complete, vehicle, p, item)
    call(vehicle, "transmitPartItem", p)
    local inventory = World.inventory(body)
    local room = select(2, call(inventory, "hasRoomFor", body, item))
    local added, value = false, nil
    if room == true then added, value = call(inventory, "AddItem", item) end
    if not added or value ~= item or World.containsExact(inventory, item) ~= true then
        local square = select(2, call(body, "getCurrentSquare")) or World.square(Body.position(body))
        local dropped, dropValue = call(square, "AddWorldInventoryItem", item, 0.5, 0.5, 0)
        if not dropped or dropValue ~= item then
            return nil, "removed part could not be stored; custody uncertain"
        end
        return item, "dropped"
    end
    return item
end

-- Best replacement item for a slot from Goblin inventory (or nil).
local function carriedFor(body, p, preferId, excludeId)
    local types = itemTypes(p)
    local best, bestScore
    for _, item in ipairs(World.items(World.inventory(body))) do
        if types[World.fullType(item)] and not Transfer.protected(body, item)
            and (not excludeId or Transfer.itemId(item) ~= excludeId) then
            if preferId and Transfer.itemId(item) == preferId then return item end
            local condition = num(item, "getCondition") or 0
            local charge = num(item, "getCurrentUsesFloat") or 0
            local score = condition + charge * 100
            if condition > 0 and (not best or score > bestScore) then best, bestScore = item, score end
        end
    end
    return best
end

local function nearbyReplacement(body, p, anchor, runtime, excludeId)
    local types = itemTypes(p)
    runtime.partCache = runtime.partCache or {}
    for _, source in ipairs(World.cachedNear(runtime.partCache, anchor, function(item)
        return types[World.fullType(item)] and not Transfer.protected(body, item)
            and (not excludeId or Transfer.itemId(item) ~= excludeId)
            and (num(item, "getCondition") or 0) > 0 end, body)) do
        if not (runtime.skippedItems and runtime.skippedItems[source.item]) then return source end
    end
    return nil
end

-- ---------------------------------------------------------------- prepare

local function base(body, owner, request, destructive)
    if type(request) ~= "table" or request.autonomous == true
        or (destructive and request.explicit_owner_order ~= true) then
        return nil, "vehicle work requires an explicit order from the online owner"
    end
    local ownerName = select(2, call(owner, "getUsername"))
    if ownerName ~= Body.owner(body) or not online(ownerName) then
        return nil, "the owning player must be online"
    end
    local point = Body.position(owner)
    if not Support.validPoint(point) then return nil, "owner position unavailable" end
    local vehicle = Service.nearestVehicle(point)
    if not vehicle then return nil, "no vehicle within "..World.range().." tiles" end
    if not Policy.access(body, vehicle) then return nil, "safehouse rules forbid working on that vehicle" end
    local ids = identity(vehicle)
    local p = position(vehicle)
    return { owner=ownerName, vehicle_id=ids.id, vehicle_sql=ids.sql,
        anchor={ x=p.x, y=p.y, z=p.z } }, vehicle
end

-- --------------------------------------------------------------- INSPECT

function Service.report(vehicle)
    local report = { parts_missing=0, parts_worn={}, tires={} }
    local tank = part(vehicle, "GasTank")
    if tank and installed(tank) then
        report.fuel = num(tank, "getContainerContentAmount")
        report.fuel_capacity = num(tank, "getContainerCapacity")
    end
    report.battery = num(vehicle, "getBatteryCharge")
    local engine = part(vehicle, "Engine")
    report.engine = engine and num(engine, "getCondition") or nil
    for _, id in ipairs(TIRES) do
        local tire = part(vehicle, id)
        if tire then
            report.tires[#report.tires+1] = { id=id, present=installed(tire) ~= nil,
                pressure=num(tire, "getContainerContentAmount"), capacity=num(tire, "getContainerCapacity"),
                condition=num(tire, "getCondition") }
        end
    end
    local count = num(vehicle, "getPartCount") or 0
    for index = 0, math.min(count, 128) - 1 do
        local p = select(2, call(vehicle, "getPartByIndex", index))
        if p and not empty(itemTypes(p)) then
            if not installed(p) then report.parts_missing = report.parts_missing + 1
            else
                local condition = num(p, "getCondition")
                if condition and condition < 40 and #report.parts_worn < 16 then
                    report.parts_worn[#report.parts_worn+1] = select(2, call(p, "getId"))
                end
            end
        end
    end
    return report
end

function Service.summary(report)
    local flats, missingTires = 0, 0
    for _, tire in ipairs(report.tires) do
        if not tire.present then missingTires = missingTires + 1
        elseif tire.capacity and tire.pressure and tire.pressure < tire.capacity * 0.8 then flats = flats + 1 end
    end
    local fuel = report.fuel and report.fuel_capacity and report.fuel_capacity > 0
        and string.format("%d%%", math.floor(report.fuel / report.fuel_capacity * 100 + 0.5)) or "unknown"
    local battery = report.battery and string.format("%d%%", math.floor(report.battery * 100 + 0.5)) or "none"
    return string.format("fuel %s, battery %s, engine %s, %d low tire(s), %d missing tire(s), %d missing part(s), worn: %s",
        fuel, battery, tostring(report.engine or "unknown"), flats, missingTires, report.parts_missing,
        #report.parts_worn > 0 and table.concat(report.parts_worn, ",") or "none")
end

Service.Inspect = {}
function Service.Inspect.prepare(body, owner, request)
    local payload, why = base(body, owner, request, false)
    if not payload then return nil, why end
    return payload, "inspecting the nearby vehicle"
end
function Service.Inspect.update(body, payload, runtime, now)
    local vehicle, why, code = Service.resolve(payload)
    if not vehicle then return true, false, why, code end
    local square = select(2, call(vehicle, "getSquare")) or World.square(position(vehicle))
    if not Support.work(body, runtime, square, now, 3000, "REPAIR", "inspecting the vehicle") then return false end
    local report = Service.report(vehicle)
    Body.data(body).GoblinVehicleReport = report
    return true, true, "vehicle inspected: "..Service.summary(report), "COMPLETE"
end
Service.Inspect.clear = function(body) local d = Body.data(body); if d then d.GoblinAction = "" end end

-- ---------------------------------------------------------------- REFUEL

local function petrol(item)
    local fluid = select(2, call(item, "getFluidContainer"))
    if not fluid then return nil end
    local Fluid = rawget(_G, "Fluid")
    local has = Fluid and select(2, call(fluid, "contains", Fluid.Petrol))
    local amount = num(fluid, "getAmount") or 0
    if has == true and amount > 0 then return fluid, amount end
    return nil
end

local function pumpNear(vehicle, tank)
    local area = select(2, call(tank, "getArea"))
    local center = area and select(2, call(vehicle, "getAreaCenter", area))
    local x, y = num(center, "getX"), num(center, "getY")
    local z = num(vehicle, "getZ") or 0
    if not x or not y then return nil end
    for dy = -2, 2 do for dx = -2, 2 do
        local square = World.square({ x=x+dx, y=y+dy, z=z })
        for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
            local amount = num(object, "getPipedFuelAmount")
            if amount and amount > 0 then return object, amount end
        end
    end end
    return nil
end

Service.Refuel = {}
function Service.Refuel.prepare(body, owner, request)
    local payload, vehicle = base(body, owner, request, true)
    if not payload then return nil, vehicle end
    local ok, why = Service.parked(vehicle, true)
    if not ok then return nil, why end
    local tank = part(vehicle, "GasTank")
    if not tank or not installed(tank) then return nil, "this vehicle has no gas tank installed" end
    payload.added = 0
    payload.cans = {}
    return payload, "refuelling the vehicle with real petrol"
end
function Service.Refuel.update(body, payload, runtime, now)
    local vehicle, why, code = Service.resolve(payload)
    if not vehicle then return true, false, why, code end
    local ok, reason, parkedCode = Service.parked(vehicle, true)
    if not ok then return true, false, reason, parkedCode end
    local tank = part(vehicle, "GasTank")
    if not tank or not installed(tank) then return true, false, "gas tank was removed", "TARGET_CHANGED" end
    local amount, capacity = num(tank, "getContainerContentAmount"), num(tank, "getContainerCapacity")
    if not amount or not capacity then return true, false, "tank level unreadable", "ENGINE_ERROR" end
    local free = capacity - amount
    local function finish(success, codeName, extra)
        local text = string.format("added %.1f L of petrol; tank now %.1f/%.1f L", payload.added or 0, amount, capacity)
        if extra then text = text.."; "..extra end
        return true, success, text, codeName
    end
    if free < 0.05 then return finish(true, "COMPLETE") end
    local square, area = workSquare(vehicle, tank)
    local pump, pumpUnits = pumpNear(vehicle, tank)
    local can
    for _, item in ipairs(World.items(World.inventory(body))) do
        if petrol(item) then can = item; break end
    end
    if not can and not pump then
        local Provision = require("GoblinSurvivor/GoblinProvision")
        if Provision.enabled() then
            local conjured = Provision.fluid(body, "Base.PetrolCan", "Petrol", "refuelling")
            if conjured and petrol(conjured) then can = conjured end
        end
    end
    if not can and not pump then
        local source = runtime.source
        if not source then
            for _, candidate in ipairs(World.sourcesNear(payload.anchor, function(item) return petrol(item) ~= nil end, body)) do
                if not (runtime.skippedItems and runtime.skippedItems[candidate.item]) then source = candidate; break end
            end
            runtime.source, runtime.sourceAt = source, now
        end
        if not source then
            return finish((payload.added or 0) > 0, (payload.added or 0) > 0 and "COMPLETE" or "MISSING_MATERIAL",
                "no more real petrol nearby")
        end
        if World.approach(body, source.square, now) then
            local taken = Transfer.pickup(body, source)
            runtime.source = nil
            if not taken then
                runtime.skippedItems = runtime.skippedItems or {}
                runtime.skippedItems[source.item] = true
            else
                local id = Transfer.itemId(source.item)
                local p = World.point(source.square)
                payload.cans[#payload.cans+1] = { id=id, x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z) }
            end
        elseif now - (runtime.sourceAt or now) > 30000 then
            runtime.skippedItems = runtime.skippedItems or {}
            runtime.skippedItems[source.item] = true
            runtime.source = nil
        end
        return false
    end
    if not square then return true, false, "the fuel inlet is inaccessible", "BLOCKED" end
    if not Support.work(body, runtime, square, now, 3000, "REPAIR", "refuelling the vehicle") then return false end
    if area and not atArea(body, vehicle, area) then
        runtime.readyAt = nil
        return true, false, "I cannot reach the fuel inlet", "NO_PATH"
    end
    runtime.readyAt = nil
    if can then
        local fluid, available = petrol(can)
        local take = math.min(free, available)
        call(body, "setPrimaryHandItem", can)
        call(fluid, "adjustAmount", available - take)
        local left = num(fluid, "getAmount")
        if not left or math.abs(left - (available - take)) > 0.01 then
            return true, false, "petrol can did not change; tank untouched", "ENGINE_ERROR"
        end
        call(tank, "setContainerContentAmount", amount + take)
        call(vehicle, "transmitPartModData", tank)
        call(can, "syncItemFields")
        local now_amount = num(tank, "getContainerContentAmount")
        if not now_amount or now_amount < amount + take - 0.01 then
            return true, false, "petrol left the can but the tank level did not rise; inspect before retrying",
                "ENGINE_ERROR"
        end
        payload.added = (payload.added or 0) + take
        print("[GoblinSurvivor] VEHICLE_REFUEL source=can owner="..tostring(payload.owner)
            .." litres="..tostring(take).." item_id="..tostring(Transfer.itemId(can)))
        -- An emptied conjured can is discarded, never kept or handed over.
        local Provision = require("GoblinSurvivor/GoblinProvision")
        if Provision.isConjured(can) and (num(fluid, "getAmount") or 0) <= 0.001 then
            if select(2, call(body, "getPrimaryHandItem")) == can then call(body, "setPrimaryHandItem", nil) end
            call(World.inventory(body), "DoRemoveItem", can)
        end
        return false
    end
    -- Pump: 8 pump units = one 10 L jerry can (ISRefuelFromGasPump).
    local litresPerUnit = (type(Vehicles) == "table" and Vehicles.JerryCanLitres or 10) / 8
    local take = math.min(free, pumpUnits * litresPerUnit)
    local pumpTarget = math.ceil(pumpUnits - take / litresPerUnit)
    call(pump, "setPipedFuelAmount", pumpTarget)
    call(tank, "setContainerContentAmount", amount + take)
    call(vehicle, "transmitPartModData", tank)
    payload.added = (payload.added or 0) + take
    print("[GoblinSurvivor] VEHICLE_REFUEL source=pump owner="..tostring(payload.owner).." litres="..tostring(take))
    return false
end
Service.Refuel.clear = Service.Inspect.clear

-- ------------------------------------------------------------ INFLATE

local function inflateAll(body, vehicle, runtime, now, payload)
    local pump = Tools.ensure(body, "Base.TirePump")
    if not pump then return true, false, "the tire pump is unavailable", "MISSING_TOOL" end
    for _, id in ipairs(TIRES) do
        local tire = part(vehicle, id)
        local pressure = tire and installed(tire) and num(tire, "getContainerContentAmount")
        local capacity = tire and num(tire, "getContainerCapacity")
        if pressure and capacity and pressure < capacity - 0.5
            and not (runtime.inflateSkipped and runtime.inflateSkipped[id]) then
            local square, area = workSquare(vehicle, tire)
            if not square then
                runtime.inflateSkipped = runtime.inflateSkipped or {}
                runtime.inflateSkipped[id] = true
                return false
            end
            call(body, "setPrimaryHandItem", pump)
            if not Support.work(body, runtime, square, now, math.max(2000, math.min(15000,
                (capacity - pressure) * 100 * 16.67 / 10)), "REPAIR", "inflating "..id) then
                return false
            end
            runtime.readyAt = nil
            if area and not atArea(body, vehicle, area) then
                runtime.inflateSkipped = runtime.inflateSkipped or {}
                runtime.inflateSkipped[id] = true
                return false
            end
            call(tire, "setContainerContentAmount", capacity, true, true)
            local wheel = num(tire, "getWheelIndex")
            if wheel then call(vehicle, "setTireInflation", wheel, 1.0) end
            call(vehicle, "transmitPartModData", tire)
            if (num(tire, "getContainerContentAmount") or 0) < capacity - 0.5 then
                return true, false, id.." did not hold pressure; replace the tire", "ENGINE_ERROR"
            end
            payload.inflated = (payload.inflated or 0) + 1
            return false
        end
    end
    return nil
end

-- ----------------------------------------------- INSTALL / REMOVE / REPLACE

local function partPayload(body, owner, request, mode)
    local payload, vehicle = base(body, owner, request, true)
    if not payload then return nil, vehicle end
    local ok, why = Service.parked(vehicle, false)
    if not ok then return nil, why end
    local id = type(request.part) == "string" and request.part or nil
    if mode == "tire" and not id then
        -- Worst tire: missing, then lowest condition/pressure.
        local worst, score
        for _, tireId in ipairs(TIRES) do
            local tire = part(vehicle, tireId)
            if tire then
                local s = installed(tire) and ((num(tire, "getCondition") or 100)
                    + (num(tire, "getContainerContentAmount") or 0)) or -1
                if not worst or s < score then worst, score = tireId, s end
            end
        end
        id = worst
    end
    if not id or not string.match(id, "^[%w_]+$") then return nil, "name the vehicle part (for example TireFrontLeft or Battery)" end
    local p = part(vehicle, id)
    if not p then return nil, "this vehicle has no part named "..id end
    id = select(2, call(p, "getId")) or id
    payload.part = id
    payload.mode = mode
    payload.item = type(request.item) == "string" and request.item or nil
    return payload, vehicle, p
end

Service.Part = {}
function Service.Part.prepare(body, owner, request, mode)
    local payload, vehicle, p = partPayload(body, owner, request, mode)
    if not payload then return nil, vehicle end
    if mode == "remove" or ((mode == "replace" or mode == "tire") and installed(p)) then
        local plan, why = Service.eligible(body, vehicle, p, "uninstall")
        if not plan then return nil, why end
    end
    if mode == "install" and installed(p) then return nil, payload.part.." already has a part installed" end
    if mode == "remove" and not installed(p) then return nil, payload.part.." is already empty" end
    payload.stage = (mode == "install" or not installed(p)) and "install" or "remove"
    return payload, (mode == "remove" and "removing " or "servicing ")..payload.part
end

local function finishPart(payload, success, code, text)
    return true, success, text, code
end

function Service.Part.update(body, payload, runtime, now)
    local vehicle, why, code = Service.resolve(payload)
    if not vehicle then return true, false, why, code end
    local ok, reason, parkedCode = Service.parked(vehicle, false)
    if not ok then return true, false, reason, parkedCode end
    local p = part(vehicle, payload.part)
    if not p then return true, false, "part slot disappeared", "TARGET_CHANGED" end
    -- Restart reconciliation by native item ID.
    if payload.stage == "install" and payload.installing_id then
        local current = installed(p)
        if current and Transfer.itemId(current) == payload.installing_id then
            payload.stage = "done"
        end
    end
    if payload.stage == "remove" and payload.removed_id and not installed(p) then
        payload.stage = (payload.mode == "remove") and "done" or "install"
    end
    if payload.stage == "done" then
        closeCover(vehicle, runtime)
        if payload.mode == "tire" or (payload.mode ~= "remove" and string.find(payload.part, "^Tire")) then
            local inflated, inflateOK, inflateText, inflateCode = inflateAll(body, vehicle, runtime, now, payload)
            if inflated == false then return false end
            if inflated == true then return true, inflateOK, inflateText, inflateCode end
        end
        local text = payload.mode == "remove" and (payload.part.." removed; the part is with Goblin")
            or (payload.part.." installed")
        return finishPart(payload, true, "COMPLETE", text)
    end
    local mode = payload.stage == "remove" and "uninstall" or "install"
    local item
    if mode == "install" then
        item = carriedFor(body, p, payload.installing_id, payload.removed_id)
        if payload.item and item and World.fullType(item) ~= payload.item then item = nil end
        if not item then
            -- Conjure the replacement part for Goblin's own install.
            local Provision = require("GoblinSurvivor/GoblinProvision")
            local types = itemTypes(p)
            local choices = {}
            if payload.item and types[payload.item] then choices[1] = payload.item end
            -- Script order lists the basic variant first; take the first installed one.
            for _, value in ipairs(World.values(select(2, call(p, "getItemType")))) do
                choices[#choices+1] = tostring(value)
            end
            if Provision.enabled() then
                for _, wanted in ipairs(choices) do
                    if Provision.validType(wanted) then
                        local created = Provision.create(body, wanted, 1, "vehicle part "..tostring(payload.part))
                        if created and created[1] then return false end
                        break
                    end
                end
            end
        end
        if not item then
            local source = runtime.source or nearbyReplacement(body, p, payload.anchor, runtime, payload.removed_id)
            if not source then
                return finishPart(payload, false, "MISSING_MATERIAL", "no usable "..payload.part
                    .." replacement in Goblin supplies or within 150 tiles"
                    ..(payload.removed_id and "; the old part was removed and is with Goblin" or ""))
            end
            runtime.source, runtime.sourceAt = source, runtime.sourceAt or now
            if World.approach(body, source.square, now) then
                runtime.source, runtime.sourceAt = nil, nil
                if not Transfer.pickup(body, source) then
                    runtime.skippedItems = runtime.skippedItems or {}
                    runtime.skippedItems[source.item] = true
                end
            elseif now - runtime.sourceAt > 30000 then
                runtime.skippedItems = runtime.skippedItems or {}
                runtime.skippedItems[source.item] = true
                runtime.source, runtime.sourceAt = nil, nil
            end
            return false
        end
    end
    local plan, planWhy, planCode = Service.eligible(body, vehicle, p, mode, item)
    if not plan then return finishPart(payload, false, planCode, planWhy) end
    local square, area = workSquare(vehicle, p)
    if not square then return true, false, "the part's work area is inaccessible", "BLOCKED" end
    equip(body, plan.tools)
    if not Support.work(body, runtime, square, now, duration(body, plan.tbl), "REPAIR",
        (mode == "install" and "installing " or "removing ")..payload.part) then
        return false
    end
    runtime.readyAt = nil
    if area and not atArea(body, vehicle, area) then
        return true, false, "I cannot reach the "..payload.part.." work area", "NO_PATH"
    end
    local coverOK, coverWhy = openCover(vehicle, script(p, "install"), runtime)
    if not coverOK then return true, false, coverWhy, "LOCKED" end
    -- Recheck immediately before mutation.
    plan, planWhy, planCode = Service.eligible(body, vehicle, p, mode, item)
    if not plan then closeCover(vehicle, runtime); return finishPart(payload, false, planCode, planWhy) end
    runtime.attempts = (runtime.attempts or 0) + 1
    if mode == "install" then
        payload.installing_id = Transfer.itemId(item)
        local done, detail = Service.installPart(body, vehicle, p, item, plan)
        if done == nil then
            closeCover(vehicle, runtime)
            return true, false, detail, "ENGINE_ERROR"
        end
        if done == false then
            if runtime.attempts >= 3 then
                closeCover(vehicle, runtime)
                return true, false, "install failed three skill rolls; the part is still with Goblin", "BLOCKED"
            end
            return false
        end
        print("[GoblinSurvivor] VEHICLE_PART stage=install owner="..tostring(payload.owner)
            .." part="..payload.part.." item_id="..tostring(payload.installing_id))
        payload.stage = "done"
        runtime.attempts = 0
        return false
    end
    local removed, detail = Service.uninstallPart(body, vehicle, p, plan)
    if removed == nil then closeCover(vehicle, runtime); return true, false, detail, "ENGINE_ERROR" end
    if removed == false then
        if runtime.attempts >= 3 then
            closeCover(vehicle, runtime)
            return true, false, "removal failed three skill rolls", "BLOCKED"
        end
        return false
    end
    payload.removed_id = Transfer.itemId(removed)
    print("[GoblinSurvivor] VEHICLE_PART stage=remove owner="..tostring(payload.owner)
        .." part="..payload.part.." item_id="..tostring(payload.removed_id).." detail="..tostring(detail or ""))
    runtime.attempts = 0
    payload.stage = payload.mode == "remove" and "done" or "install"
    return false
end
Service.Part.clear = Service.Inspect.clear

local function partHandler(mode)
    return {
        prepare=function(body, owner, request) return Service.Part.prepare(body, owner, request, mode) end,
        update=Service.Part.update, clear=Service.Part.clear }
end
Service.Install = partHandler("install")
Service.Remove = partHandler("remove")
Service.Replace = partHandler("replace")
Service.Tire = partHandler("tire")

-- ------------------------------------------------------ VEHICLE_SERVICE

-- Battery charging: Goblin hooks the installed battery to his own conjured
-- charger (no charger item is placed in the world) and tops it up in place.
local CHARGE_MS = 8000
function Service.chargeBattery(body, vehicle, runtime, now, payload)
    if payload.battery_charged ~= nil then return true, true end
    local p = part(vehicle, "Battery")
    local item = installed(p)
    if not item then payload.battery_charged = false; return true, true end
    local charge = num(item, "getCurrentUsesFloat") or num(vehicle, "getBatteryCharge") or 1
    if charge >= 0.99 then payload.battery_charged = false; return true, true end
    runtime.chargeUntil = runtime.chargeUntil or (now + CHARGE_MS)
    if now < runtime.chargeUntil then
        Support.status(body, "charging the battery")
        return false
    end
    runtime.chargeUntil = nil
    local set = call(item, "setCurrentUsesFloat", 1.0)
    if not set then set = call(item, "setUsedDelta", 1.0) end
    call(vehicle, "transmitPartUsedDelta", p)
    call(vehicle, "transmitPartItem", p)
    local after = num(item, "getCurrentUsesFloat") or num(vehicle, "getBatteryCharge") or 0
    if not set or after < 0.99 then
        payload.battery_charged = false
        return true, false, "the battery would not take a charge", "ENGINE_ERROR"
    end
    payload.battery_charged = true
    print("[GoblinSurvivor] VEHICLE_BATTERY_CHARGED owner="..tostring(payload.owner)
        .." from="..string.format("%.2f", charge))
    return true, true
end

-- Inspect, inflate every low tire, charge the battery, then top up fuel.
Service.Full = {}
function Service.Full.prepare(body, owner, request)
    local payload, vehicle = base(body, owner, request, true)
    if not payload then return nil, vehicle end
    local ok, why = Service.parked(vehicle, true)
    if not ok then return nil, why end
    payload.phase = "inspect"
    payload.added, payload.cans, payload.inflated = 0, {}, 0
    return payload, "servicing the nearby vehicle: inspection, tires, battery, fuel"
end
function Service.Full.update(body, payload, runtime, now)
    local vehicle, why, code = Service.resolve(payload)
    if not vehicle then return true, false, why, code end
    if payload.phase == "inspect" then
        local done, success, detail, resultCode = Service.Inspect.update(body, payload, runtime, now)
        if not done then return false end
        if not success then return done, success, detail, resultCode end
        payload.phase = "tires"
        return false
    end
    if payload.phase == "tires" then
        local done, success, detail, resultCode = inflateAll(body, vehicle, runtime, now, payload)
        if done == false then return false end
        if done == true and not success and resultCode ~= "MISSING_TOOL" then
            return done, success, detail, resultCode
        end
        payload.phase = "battery"
        return false
    end
    if payload.phase == "battery" then
        local done, success, detail, resultCode = Service.chargeBattery(body, vehicle, runtime, now, payload)
        if not done then return false end
        if not success then return done, success, detail, resultCode end
        payload.phase = "fuel"
        return false
    end
    local done, success, detail, resultCode = Service.Refuel.update(body, payload, runtime, now)
    if not done then return false end
    local report = Service.report(vehicle)
    Body.data(body).GoblinVehicleReport = report
    local text = string.format("service finished: %d tire(s) inflated, %sbattery, %.1f L added; %s",
        payload.inflated or 0, payload.battery_charged and "charged the " or "checked the ",
        payload.added or 0, Service.summary(report))
    if resultCode == "MISSING_MATERIAL" then
        return true, true, text.." (no petrol was available)", "COMPLETE"
    end
    return true, success, text, success and "COMPLETE" or resultCode
end
Service.Full.clear = Service.Inspect.clear

return Service
