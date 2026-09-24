-- Read-only, bounded survey of the exact saved-base BuildingDef.
-- The report records observed facts, never treats an unloaded square as clear.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Curtains = require("GoblinSurvivor/GoblinCurtains")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
local Stockpiles = require("GoblinSurvivor/GoblinStockpiles")

local Inspect = {}
local call = World.call
local MAX_SQUARES = 2048
local MAX_FINDINGS = 64

local function kind(object, name)
    if type(instanceof) == "function" then
        local ok, value = pcall(instanceof, object, name)
        return ok and value == true
    end
    return object and object.kind == name
end

local function area(scope)
    local seen, points = {}, {}
    for _, room in ipairs(scope.rooms) do
        for x = room.x - 1, room.x2 + 1 do
            for y = room.y - 1, room.y2 + 1 do
                local key = x .. ":" .. y .. ":" .. room.z
                if not seen[key] then
                    seen[key] = true
                    points[#points + 1] = { x = x, y = y, z = room.z }
                    if #points > MAX_SQUARES then return nil end
                end
            end
        end
    end
    return points
end

local function add(report, category, point, object)
    report[category] = report[category] + 1
    if #report.findings < MAX_FINDINGS then
        local _, index = call(object, "getObjectIndex")
        report.findings[#report.findings + 1] = {
            category = category, x = point.x, y = point.y, z = point.z,
            object_index = type(index) == "number" and index >= 0 and index or nil
        }
    else
        report.findings_truncated = true
    end
end

local function damaged(object)
    local okHealth, health = call(object, "getHealth")
    local okMax, maximum = call(object, "getMaxHealth")
    return okHealth and okMax and tonumber(maximum) and maximum > 0
        and tonumber(health) and health < maximum
end

local function inspectBarricade(report, barricade, point, seen)
    if not barricade or seen[barricade] then return end
    seen[barricade] = true
    if damaged(barricade) then add(report, "damaged_barricades", point, barricade) end
end

local function inspectObject(report, object, point, seenBarricades)
    if kind(object, "IsoWindow") then
        local _, smashed = call(object, "isSmashed")
        local _, exterior = call(object, "isExterior")
        local _, barricaded = call(object, "isBarricaded")
        if smashed == true then add(report, "broken_windows", point, object) end
        if exterior == true and barricaded == false then
            add(report, "unbarricaded_windows", point, object)
        end
    elseif kind(object, "IsoDoor") or kind(object, "IsoThumpable") then
        local door = kind(object, "IsoDoor")
        if not door then local checked, value = call(object, "isDoor"); door = checked and value end
        if door then
            local _, exterior = call(object, "isExterior")
            if exterior == nil then _, exterior = call(object, "isExteriorDoor", nil) end
            local _, open = call(object, "IsOpen")
            if open == nil then _, open = call(object, "isOpen") end
            if exterior == true and open == true then add(report, "open_exterior_doors", point, object) end
        end
        if damaged(object) then add(report, "damaged_structures", point, object) end
    elseif kind(object, "IsoGenerator") then
        local _, running = call(object, "isActivated")
        local _, fuel = call(object, "getFuel")
        local _, condition = call(object, "getCondition")
        if #report.generator_status < MAX_FINDINGS then
            report.generator_status[#report.generator_status + 1] = {
                x = point.x, y = point.y, z = point.z,
                running = running == true, fuel = tonumber(fuel), condition = tonumber(condition)
            }
        else report.generators_truncated = true end
    end
    local _, same = call(object, "getBarricadeOnSameSquare")
    local _, opposite = call(object, "getBarricadeOnOppositeSquare")
    inspectBarricade(report, same, point, seenBarricades)
    inspectBarricade(report, opposite, point, seenBarricades)
    if kind(object, "IsoBarricade") then inspectBarricade(report, object, point, seenBarricades) end
    local _, container = call(object, "getContainer")
    if container then
        local _, capacity = call(container, "getCapacity")
        local _, weight = call(container, "getContentsWeight")
        if tonumber(capacity) and capacity > 0 and tonumber(weight)
            and weight / capacity >= 0.85 then add(report, "storage_nearly_full", point, object) end
    end
end

local function cropNeedsAttention(square)
    local farm = SFarmingSystem and SFarmingSystem.instance
    local ok, plant = call(farm, "getLuaObjectOnSquare", square)
    if not ok or not plant then return false end
    if plant.hasVegetable == true then return true end
    if plant.state == "plow" or plant.state == "rotten" then return false end
    return type(plant.waterLvl) == "number" and type(plant.waterNeeded) == "number"
        and plant.waterLvl < plant.waterNeeded
end

function Inspect.scan(scope, body, now)
    local points = area(scope)
    if not points then return nil, "base exceeds the 2048-square survey limit", "UNSUPPORTED" end
    local report = {
        building_id = scope.id, timestamp_ms = now, stale = false,
        squares_expected = #points, squares_scanned = 0, squares_unloaded = 0,
        squares_inaccessible = 0, squares_outside_building = 0,
        partial = scope.partiallyStreamed == true,
        unbarricaded_windows = 0, damaged_barricades = 0,
        damaged_structures = 0, open_exterior_doors = 0, broken_windows = 0,
        storage_nearly_full = 0, crops_needing_attention = 0, nearby_threats = 0,
        missing_supplies = { status = "NOT_CONFIGURED" },
        generator_status = {}, generators_truncated = false,
        findings = {}, findings_truncated = false
    }
    local seenBarricades, seenThreats = {}, {}
    for _, point in ipairs(points) do
        local square = World.square(point)
        if not square then
            report.squares_unloaded = report.squares_unloaded + 1
            report.partial = true
        elseif not Curtains.belongsToScope(scope, square) then
            report.squares_outside_building = report.squares_outside_building + 1
        elseif not Policy.access(body, { getSquare = function() return square end }) then
            report.squares_inaccessible = report.squares_inaccessible + 1
            report.partial = true
        else
            report.squares_scanned = report.squares_scanned + 1
            for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                inspectObject(report, object, point, seenBarricades)
            end
            if cropNeedsAttention(square) then add(report, "crops_needing_attention", point) end
            for _, actor in ipairs(World.values(select(2, call(square, "getMovingObjects")))) do
                if actor ~= body and not seenThreats[actor] and kind(actor, "IsoZombie")
                    and not Body.isGoblin(actor) then
                    seenThreats[actor] = true
                    add(report, "nearby_threats", point)
                end
            end
        end
    end
    if #report.generator_status == 0 then
        report.generator_status = { status = report.partial and "UNKNOWN" or "NONE_OBSERVED" }
    end
    report.missing_supplies = Stockpiles.scan(scope, body)
    return report
end

function Inspect.prepare(body, owner)
    local data = Body.data(body)
    if not data or data.GoblinBaseSet ~= true then return nil, "set a base inside a house first" end
    local anchor = { x = tonumber(data.GoblinBaseX), y = tonumber(data.GoblinBaseY),
        z = tonumber(data.GoblinBaseZ) }
    if not Support.validPoint(anchor) then return nil, "saved base position is invalid" end
    local scope, why = Curtains.scopeAt(anchor)
    if not scope then return nil, "saved base house is unavailable: " .. tostring(why) end
    local permitted, _, reason = Policy.access(body,
        { getSquare = function() return World.square(anchor) end })
    if not permitted then return nil, reason end
    if not area(scope) then return nil, "base exceeds the 2048-square survey limit" end
    if type(data.GoblinBaseReport) == "table" then data.GoblinBaseReport.stale = true end
    return { anchor = anchor, building_id = scope.id }, "base inspection queued"
end

function Inspect.update(body, payload, job, now)
    local scope = Curtains.scopeAt(payload.anchor)
    if not scope or scope.id ~= payload.building_id then
        return true, false, "saved base house is unloaded or changed", "TARGET_UNLOADED"
    end
    local square = World.square(payload.anchor)
    if not square then return true, false, "saved base square unloaded", "TARGET_UNLOADED" end
    local permitted, code, reason = Policy.access(body,
        { getSquare = function() return square end })
    if not permitted then return true, false, reason, code end
    if not Support.work(body, job, square, now, 1500, "INSPECT", "inspecting the base") then
        return false
    end
    local report, why, code = Inspect.scan(scope, body, now)
    if not report then return true, false, why, code end
    Body.data(body).GoblinBaseReport = report
    local supplies = report.missing_supplies
    local supplyDetail = supplies.status == "NOT_CONFIGURED" and "Supply thresholds are not configured."
        or supplies.status == "UNKNOWN" and "Some configured supply counts are unknown."
        or supplies.status == "MISSING" and "Configured supplies are short."
        or "Configured supplies meet their thresholds."
    Body.say(body, string.format(
        "Comrade, base survey%s: %d unbarricaded windows, %d open exterior doors, %d broken windows, %d nearby threats. %s",
        report.partial and " is partial" or " complete",
        report.unbarricaded_windows, report.open_exterior_doors,
        report.broken_windows, report.nearby_threats, supplyDetail))
    if report.partial then
        return true, false, "base inspection partial; some areas are unloaded or inaccessible",
            report.squares_unloaded > 0 and "TARGET_UNLOADED" or "BLOCKED"
    end
    return true, true, "base inspection complete", "COMPLETE"
end

function Inspect.clear(body)
    local data = Body.data(body)
    if data then data.GoblinAction = "" end
end

return Inspect
