-- RESTORE_POWER: Goblin gets the base electricity running on his own.
--
-- He looks for a loaded IsoGenerator near the base (or the owner). With none
-- he conjures a Base.Generator and places it on a free OUTDOOR square beside
-- the house the way the engine's own map/moveable code does
-- (IsoGenerator.new + transmitCompleteItemToClients), never indoors (fumes).
-- Then he repairs it to full condition, fills it with conjured petrol poured
-- the way ISAddFuel does, plugs it in (setConnected) and starts it
-- (setActivated), syncing each change to clients.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")

local Power = { SEARCH_RADIUS = 20, PLACE_RADIUS = 8, STEP_MS = 3000 }
local call = World.call

local function isGenerator(object)
    if object == nil then return false end
    if type(instanceof) == "function" then
        local ok, value = pcall(instanceof, object, "IsoGenerator")
        if ok then return value == true end
    end
    return type(object) == "table" and object.isGenerator == true
end

local function num(object, method)
    local ok, value = call(object, method)
    return ok and tonumber(value) or nil
end

local function playerFor(name)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return nil end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return player end
    end
    return nil
end

local function anchorFor(body, owner)
    local data = Body.data(body)
    if data and data.GoblinBaseSet == true then
        local p = { x = tonumber(data.GoblinBaseX), y = tonumber(data.GoblinBaseY), z = tonumber(data.GoblinBaseZ) }
        if p.x and p.y and p.z then return { x = math.floor(p.x), y = math.floor(p.y), z = math.floor(p.z) } end
    end
    local p = Body.position(owner)
    if not Support.validPoint(p) then return nil end
    return { x = math.floor(p.x), y = math.floor(p.y), z = math.floor(p.z) }
end

local function allowed(body, square)
    return Policy.access(body, { getSquare = function() return square end }) == true
end

function Power.findGenerator(body, anchor, radius)
    radius = radius or Power.SEARCH_RADIUS
    local best, bestDistance
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = World.square({ x = anchor.x + dx, y = anchor.y + dy, z = anchor.z })
            if square then
                for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                    local distance = dx * dx + dy * dy
                    if isGenerator(object) and (not best or distance < bestDistance) and allowed(body, square) then
                        best, bestDistance = object, distance
                    end
                end
            end
        end
    end
    return best
end

local function freeOutdoor(square)
    local _, outside = call(square, "isOutside")
    if outside ~= true then return false end
    local _, free = call(square, "isFree", false)
    if free ~= true then return false end
    local _, floor = call(square, "isSolidFloor")
    if floor == false then return false end
    local _, vehicle = call(square, "getVehicleContainer")
    if vehicle ~= nil then return false end
    local objects = World.values(select(2, call(square, "getObjects")))
    return #objects <= 1 -- the floor only
end

-- Nearest free outdoor square to the base, in growing rings.
function Power.placementSquare(body, anchor)
    for r = 1, Power.PLACE_RADIUS do
        local best, bestDistance
        for dx = -r, r do
            for dy = -r, r do
                local distance = dx * dx + dy * dy
                if math.max(math.abs(dx), math.abs(dy)) == r and (not best or distance < bestDistance) then
                    local square = World.square({ x = anchor.x + dx, y = anchor.y + dy, z = anchor.z })
                    if square and freeOutdoor(square) and allowed(body, square) then best, bestDistance = square, distance end
                end
            end
        end
        if best then return best end
    end
    return nil
end

function Power.place(square)
    if type(instanceItem) ~= "function" or not rawget(_G, "IsoGenerator") then return nil, "generators are unavailable" end
    local ok, item = pcall(instanceItem, "Base.Generator")
    if not ok or not item then return nil, "the engine could not create a generator" end
    call(item, "setCondition", 100)
    local data = select(2, call(item, "getModData"))
    if type(data) == "table" or type(data) == "userdata" then pcall(function() data.fuel = 0 end) end
    local cell = type(getCell) == "function" and getCell() or nil
    local made, generator = pcall(IsoGenerator.new, item, cell, square)
    if not made or not generator then return nil, "the generator could not be placed" end
    call(generator, "transmitCompleteItemToClients")
    local p = { x = square:getX(), y = square:getY(), z = square:getZ() }
    print("[GoblinSurvivor] GENERATOR_PLACED x=" .. p.x .. " y=" .. p.y .. " z=" .. p.z)
    return generator
end

local function sync(generator)
    call(generator, "sync")
    local square = select(2, call(generator, "getSquare"))
    local Gen = rawget(_G, "IsoGenerator")
    if square and Gen and type(Gen.updateGenerator) == "function" then pcall(Gen.updateGenerator, square) end
end

-- Pour one conjured can of petrol (ISAddFuel:complete arithmetic).
local function refuel(body, generator)
    local fuel, maximum = num(generator, "getFuel"), num(generator, "getMaxFuel") or 100
    if not fuel then return nil, "generator fuel unreadable" end
    if maximum - fuel < 0.05 then return 0 end
    local Provision = require("GoblinSurvivor/GoblinProvision")
    local can = Provision.enabled() and Provision.fluid(body, "Base.PetrolCan", "Petrol", "generator fuel") or nil
    if not can then return nil, "no petrol to pour" end
    local container = select(2, call(can, "getFluidContainer"))
    local have = num(container, "getAmount") or 0
    local pour = math.min(have, maximum - fuel)
    call(container, "adjustAmount", have - pour)
    call(generator, "setFuel", fuel + pour)
    -- The empty conjured can goes away; it was only ever a funnel.
    local inventory = World.inventory(body)
    if Provision.isConjured(can) then
        local removed = call(inventory, "DoRemoveItem", can)
        if not removed then call(inventory, "Remove", can) end
    end
    return pour
end

function Power.prepare(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true or request.autonomous == true then
        return nil, "this job requires an explicit order from the online owner"
    end
    local name = select(2, call(owner, "getUsername"))
    if name ~= Body.owner(body) or not playerFor(name) then return nil, "the owning player must be online" end
    local anchor = anchorFor(body, owner)
    if not anchor then return nil, "owner position unavailable" end
    return { owner = name, anchor = anchor, placed = false, poured = 0, repaired = false },
        "getting the power running at the base"
end

function Power.update(body, payload, runtime, now)
    if not playerFor(payload.owner) then return true, false, "owner logged out; power work stopped", "INTERRUPTED" end
    local generator = runtime.generator
    if generator then
        local square = select(2, call(generator, "getSquare"))
        if not square then generator = nil; runtime.generator = nil end
    end
    if not generator then
        generator = Power.findGenerator(body, payload.anchor)
        if not generator then
            local Provision = require("GoblinSurvivor/GoblinProvision")
            if not Provision.enabled() then
                return true, false, "no generator near the base and conjuring is disabled", "NO_TARGET"
            end
            runtime.site = runtime.site or Power.placementSquare(body, payload.anchor)
            if not runtime.site then
                return true, false, "no free outdoor ground beside the base for a generator", "NO_TARGET"
            end
            if not Support.work(body, runtime, runtime.site, now, Power.STEP_MS, "BUILD", "setting up a generator") then
                return false
            end
            runtime.readyAt = nil
            local placed, why = Power.place(runtime.site)
            runtime.site = nil
            if not placed then return true, false, why, "ENGINE_ERROR" end
            payload.placed = true
            generator = placed
        end
        runtime.generator = generator
    end
    local square = select(2, call(generator, "getSquare"))
    if not Support.work(body, runtime, square, now, Power.STEP_MS, "LOOT", "working on the generator") then
        return false
    end
    runtime.readyAt = nil
    local condition = num(generator, "getCondition") or 100
    if condition < 100 then
        call(generator, "setCondition", 100)
        payload.repaired = true
        sync(generator)
        return false
    end
    local fuel, maximum = num(generator, "getFuel") or 0, num(generator, "getMaxFuel") or 100
    if maximum - fuel >= 0.05 then
        local poured, why = refuel(body, generator)
        if not poured then return true, false, why, "MISSING_MATERIAL" end
        payload.poured = (payload.poured or 0) + poured
        sync(generator)
        runtime.pours = (runtime.pours or 0) + 1
        if runtime.pours < 40 then return false end
    end
    if select(2, call(generator, "isConnected")) ~= true then call(generator, "setConnected", true) end
    if select(2, call(generator, "isActivated")) ~= true then call(generator, "setActivated", true) end
    sync(generator)
    local running = select(2, call(generator, "isActivated")) == true
    local text = string.format("%sgenerator %s; fuel %.1f/%.1f, condition %d%%%s", payload.placed and "placed a new " or "",
        running and "running and powering the base" or "would not start",
        num(generator, "getFuel") or 0, num(generator, "getMaxFuel") or 100, num(generator, "getCondition") or 0,
        payload.repaired and ", repaired" or "")
    print("[GoblinSurvivor] POWER owner=" .. tostring(payload.owner) .. " " .. text)
    return true, running, text, running and "COMPLETE" or "ENGINE_ERROR"
end

return Power
