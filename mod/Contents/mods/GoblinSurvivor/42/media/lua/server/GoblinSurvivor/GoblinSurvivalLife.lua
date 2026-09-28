-- Milestone 5 survival life: foraging, traps and cooking.
--
-- FORAGE     : the installed forageSystem (shared/Foraging) rolls a real item
--              for the forage zone and month at each spot Goblin searches.
--              Finds are ordinary cargo; Goblin's next delivery takes them to
--              the base (never conjured, never quarantined).
-- CHECK_TRAPS: check mode visits STrapSystem traps near the base/owner,
--              empties catches with STrapGlobalObject:removeAnimal (a live
--              catch is dispatched) and re-baits with conjured bait. Place mode
--              builds new traps server-side the way TrapBO:create does
--              (IsoThumpable + TrapSystem.initObjectModData, owned by the
--              player) from conjured trap items, then baits them.
-- COOK       : food mode puts raw cookable food in a hot stove or campfire and
--              takes it out once isCooked(). Soup/stew mode fills a fresh pot
--              with real ingredients through the installed evolved recipe
--              (EvolvedRecipe.addItem) and cooks the pot. With no stove or fire
--              nearby, Goblin builds a campfire (SCampfireSystem:addCampfire)
--              beside the owner and feeds it his own firewood.
local Body = require("GoblinSurvivor/GoblinBody")
local World = require("GoblinSurvivor/GoblinWorld")
local Support = require("GoblinSurvivor/GoblinJobSupport")
local Transfer = require("GoblinSurvivor/GoblinTransfer")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")

local Life = {}
local call = World.call

local function playerFor(name)
    if type(getOnlinePlayers) ~= "function" then return nil end
    local ok, players = pcall(getOnlinePlayers)
    if not ok then return nil end
    for _, player in ipairs(World.values(players)) do
        if select(2, call(player, "getUsername")) == name then return player end
    end
    return nil
end

local function ownerOrder(body, owner, request)
    if type(request) ~= "table" or request.explicit_owner_order ~= true or request.autonomous == true then
        return nil, "this job requires an explicit order from the online owner"
    end
    local name = select(2, call(owner, "getUsername"))
    if name ~= Body.owner(body) or not playerFor(name) then return nil, "the owning player must be online" end
    return name
end

local function anchorFor(body, owner, preferBase)
    local data = Body.data(body)
    if preferBase and data.GoblinBaseSet then
        return { x=math.floor(data.GoblinBaseX), y=math.floor(data.GoblinBaseY), z=math.floor(data.GoblinBaseZ) }
    end
    local p = Body.position(owner)
    if not Support.validPoint(p) then return nil end
    return { x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z) }
end

local function count(request, default, maximum)
    local n = tonumber(type(request) == "table" and request.count) or default
    if n ~= math.floor(n) or n < 1 or n > maximum then return nil end
    return n
end

-- Integer tile coordinates (World.point returns tile centres).
local function tile(square)
    return { x=square:getX(), y=square:getY(), z=square:getZ() }
end

local function random(n)
    if type(ZombRand) == "function" then return ZombRand(n) end
    return math.random(0, n - 1)
end

-- -------------------------------------------------------------- FORAGE

Life.Forage = {}
Life.FORAGE_RADIUS = 14
Life.FORAGE_MS = 5000

local function forageZone(square)
    local fs = rawget(_G, "forageSystem")
    if not fs or type(fs.getDefinedZoneAt) ~= "function" then return nil end
    local _, outside = call(square, "isOutside")
    if outside ~= true then return nil end
    local p = tile(square)
    local ok, zoneDef, zone = pcall(fs.getDefinedZoneAt, p.x, p.y)
    if not ok or not zoneDef then return nil end
    local name = type(zoneDef) == "table" and zoneDef.name or nil
    if not name and zone then name = select(2, call(zone, "getType")) end
    return name
end

local function forageSpot(body, anchor, tries)
    for _ = 1, tries do
        local r = Life.FORAGE_RADIUS
        local point = { x=anchor.x + random(2*r+1) - r, y=anchor.y + random(2*r+1) - r, z=anchor.z }
        local square = World.square(point)
        if square and Policy.access(body, { getSquare=function() return square end }) then
            local zone = forageZone(square)
            if zone then return square, zone end
        end
    end
    return nil
end

function Life.Forage.roll(zone)
    local fs = rawget(_G, "forageSystem")
    if not fs or type(fs.pickRandomItemType) ~= "function" then return nil end
    local ok, itemType = pcall(fs.pickRandomItemType, zone)
    if ok and type(itemType) == "string" and itemType ~= "" then return itemType end
    return nil
end

function Life.Forage.prepare(body, owner, request)
    local name, why = ownerOrder(body, owner, request)
    if not name then return nil, why end
    local n = count(request, 5, 10)
    if not n then return nil, "forage 1 to 10 finds per order" end
    local anchor = anchorFor(body, owner, false)
    if not anchor then return nil, "owner position unavailable" end
    if not rawget(_G, "forageSystem") then return nil, "the installed foraging system is not loaded" end
    if not forageSpot(body, anchor, 60) then
        return nil, "no forageable outdoor ground (forest, field, vegetation) near you"
    end
    return { owner=name, anchor=anchor, count=n, completed=0, finds={} },
        "foraging for "..n.." find(s) nearby; I will bring them home"
end

function Life.Forage.update(body, payload, runtime, now)
    if not playerFor(payload.owner) then return true, false, "owner logged out; foraging stopped", "INTERRUPTED" end
    payload.finds = payload.finds or {}
    if (payload.completed or 0) >= payload.count then
        return true, true, "foraged "..payload.completed.." find(s): "..table.concat(payload.finds, ", "), "COMPLETE"
    end
    if not runtime.spot then
        local square, zone = forageSpot(body, payload.anchor, 20)
        if not square then
            runtime.misses = (runtime.misses or 0) + 1
            if runtime.misses > 10 then
                return true, (payload.completed or 0) > 0, "found no more forageable ground nearby",
                    (payload.completed or 0) > 0 and "COMPLETE" or "NO_TARGET"
            end
            return false
        end
        runtime.spot, runtime.zone, runtime.readyAt, runtime.spotAt = square, zone, nil, now
    end
    if now - (runtime.spotAt or now) > 45000 then runtime.spot = nil; return false end
    if not Support.work(body, runtime, runtime.spot, now, Life.FORAGE_MS, "LOOT", "foraging") then return false end
    local zone = runtime.zone
    runtime.spot, runtime.zone, runtime.readyAt = nil, nil, nil
    runtime.searches = (runtime.searches or 0) + 1
    local itemType = Life.Forage.roll(zone)
    if not itemType or type(instanceItem) ~= "function" then
        if runtime.searches > payload.count * 4 then
            return true, (payload.completed or 0) > 0, "the ground here is picked clean",
                (payload.completed or 0) > 0 and "COMPLETE" or "NO_TARGET"
        end
        return false
    end
    local ok, item = pcall(instanceItem, itemType)
    if not ok or not item then return false end
    local inventory = World.inventory(body)
    local added, value = call(inventory, "AddItem", item)
    if not added or value ~= item then return false end
    payload.completed = (payload.completed or 0) + 1
    payload.finds[#payload.finds+1] = itemType
    print("[GoblinSurvivor] FORAGE owner="..tostring(payload.owner).." zone="..tostring(zone).." item="..itemType)
    return false
end

-- --------------------------------------------------------- CHECK_TRAPS

Life.Traps = {}
Life.TRAP_RADIUS = 30
Life.TRAP_PLACE_RADIUS = 12
Life.TRAP_BAIT = "Base.Carrots"
Life.TRAP_TYPE = "Base.TrapBox"

local function trapSystem()
    local system = rawget(_G, "STrapSystem")
    return system and system.instance or nil
end

local function trapsNear(anchor)
    local found, system = {}, trapSystem()
    if not system or type(system.getLuaObjectCount) ~= "function" then return found end
    local ok, total = pcall(system.getLuaObjectCount, system)
    if not ok or type(total) ~= "number" then return found end
    for index = 1, total do
        local got, trap = pcall(system.getLuaObjectByIndex, system, index)
        if got and type(trap) == "table" and trap.x and trap.z == anchor.z then
            local d = (trap.x - anchor.x)^2 + (trap.y - anchor.y)^2
            if d <= Life.TRAP_RADIUS^2 then found[#found+1] = { trap=trap, d=d } end
        end
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    return found
end

local function trapAt(x, y, z)
    local system = trapSystem()
    if not system or type(system.getLuaObjectAt) ~= "function" then return nil end
    local ok, trap = pcall(system.getLuaObjectAt, system, x, y, z)
    return ok and trap or nil
end

local function needsVisit(trap)
    if trap.destroyed then return false end
    if type(trap.animal) == "table" and trap.animal.type then return true end
    return not trap.bait
end

-- The installed trap code asks its character for a position, inventory and
-- username; this adapter answers for the Goblin without an IsoPlayer cast.
local function trapper(body, ownerName)
    local inventory = World.inventory(body)
    local p = Body.position(body)
    return {
        getX=function() return p.x end, getY=function() return p.y end, getZ=function() return p.z end,
        getInventory=function() return inventory end,
        getUsername=function() return ownerName end,
        getCurrentSquare=function() return select(2, call(body, "getCurrentSquare")) end,
        setPrimaryHandItem=function() end, setSecondaryHandItem=function() end,
    }
end

local function trapDefinition(fullType)
    for _, def in ipairs(rawget(_G, "Traps") or {}) do
        if def.type == fullType then return def end
    end
    return nil
end

local function flag(name)
    local flags = rawget(_G, "IsoFlagType")
    return flags and flags[name]
end

-- Mirrors TrapBO:isValid: free, floored, not solid, no tree, no trap, and a
-- trapping zone so animals can actually come.
function Life.Traps.siteValid(square)
    if not square then return false end
    local _, outside = call(square, "isOutside")
    if outside ~= true then return false end
    local p = tile(square)
    if trapAt(p.x, p.y, p.z) then return false end
    local _, moving = call(square, "getMovingObjects")
    local _, n = call(moving, "size")
    if (n or 0) > 0 then return false end
    for _, name in ipairs({ "solid", "solidtrans" }) do
        local f = flag(name)
        if f and select(2, call(square, "has", f)) == true then return false end
    end
    local floor = flag("solidfloor")
    if floor and select(2, call(square, "has", floor)) ~= true then return false end
    local types = rawget(_G, "IsoObjectType")
    if types and types.tree and select(2, call(square, "has", types.tree)) == true then return false end
    local TrapSystem = rawget(_G, "TrapSystem")
    if TrapSystem and type(TrapSystem.getTrapZones) == "function" then
        local ok, zones = pcall(TrapSystem.getTrapZones, square)
        if not ok or type(zones) ~= "table" then return false end
        local any = false
        for _ in pairs(zones) do any = true; break end
        if not any then return false end
    end
    return true
end

local function placeSite(body, anchor, runtime)
    runtime.tried = runtime.tried or {}
    for _ = 1, 40 do
        local r = Life.TRAP_PLACE_RADIUS
        local point = { x=anchor.x + random(2*r+1) - r, y=anchor.y + random(2*r+1) - r, z=anchor.z }
        local key = point.x..":"..point.y
        local square = World.square(point)
        if not runtime.tried[key] and square and Policy.access(body, { getSquare=function() return square end })
            and Life.Traps.siteValid(square) then
            -- Keep traps a few tiles apart.
            local spaced = true
            for _, entry in ipairs(trapsNear(point)) do if entry.d < 9 then spaced = false end end
            if spaced then return square end
        end
        runtime.tried[key] = true
    end
    return nil
end

-- Server-side TrapBO:create: the same IsoThumpable, modData and replication,
-- owned by the player, using a conjured trap item that Goblin spends.
function Life.Traps.place(body, square, owner, fullType)
    local def = trapDefinition(fullType)
    local Thumpable = rawget(_G, "IsoThumpable")
    if not def or not Thumpable then return nil, "trap definitions are not loaded" end
    local Provision = require("GoblinSurvivor/GoblinProvision")
    local created = Provision.enabled() and Provision.create(body, fullType, 1, "trap") or nil
    local item = created and created[1]
    if not item then return nil, "could not make a trap" end
    local cell = getCell()
    local ok, object = pcall(Thumpable.new, cell, square, def.sprite, false, {})
    if not ok or not object then
        call(World.inventory(body), "DoRemoveItem", item)
        return nil, "the trap object could not be built"
    end
    local snare = def.sprite == "constructedobjects_01_16" or def.sprite == "constructedobjects_01_18"
    call(object, "setName", "Trap")
    call(object, "setMaxHealth", 50)
    call(object, "setHealth", 50)
    call(object, "setCanPassThrough", snare)
    call(object, "setBlockAllTheSquare", not snare)
    call(object, "setIsThumpable", not snare)
    call(square, "AddSpecialObject", object)
    call(square, "RecalcAllWithNeighbours", true)
    local TrapSystem = rawget(_G, "TrapSystem")
    if TrapSystem then pcall(TrapSystem.initObjectModData, object, def, false, owner) end
    call(object, "transmitCompleteItemToClients")
    call(World.inventory(body), "DoRemoveItem", item)
    local p = tile(square)
    if not trapAt(p.x, p.y, p.z) and type(triggerEvent) == "function" then
        pcall(triggerEvent, "OnObjectAdded", object)
    end
    local trap = trapAt(p.x, p.y, p.z)
    if not trap then
        local system = trapSystem()
        if system and type(system.loadIsoObject) == "function" then pcall(system.loadIsoObject, system, object) end
        trap = trapAt(p.x, p.y, p.z)
    end
    if not trap then return nil, "the trap system did not register the new trap" end
    print("[GoblinSurvivor] TRAP_PLACED owner="..tostring(select(2, call(owner, "getUsername")))
        .." type="..fullType.." at="..p.x..":"..p.y..":"..p.z)
    return trap
end

local function bait(body, trap, ownerName)
    if trap.bait or trap.destroyed then return false end
    local Provision = require("GoblinSurvivor/GoblinProvision")
    local created = Provision.enabled() and Provision.create(body, Life.TRAP_BAIT, 1, "trap bait") or nil
    local item = created and created[1]
    if not item then return false end
    local ok = pcall(trap.addBait, trap, Life.TRAP_BAIT, 0, -0.05, trapper(body, ownerName))
    call(World.inventory(body), "DoRemoveItem", item)
    return ok and trap.bait ~= nil
end

function Life.Traps.prepare(body, owner, request)
    local name, why = ownerOrder(body, owner, request)
    if not name then return nil, why end
    if not trapSystem() then return nil, "the installed trap system is not loaded" end
    local place = tonumber(type(request) == "table" and request.place) or 0
    if place ~= math.floor(place) or place < 0 or place > 5 then return nil, "place 1 to 5 traps per order" end
    if place > 0 then
        local anchor = anchorFor(body, owner, false)
        if not anchor then return nil, "owner position unavailable" end
        if not placeSite(body, anchor, {}) then
            return nil, "no open outdoor ground where animals roam near you"
        end
        return { owner=name, anchor=anchor, place=place, placed=0, completed=0, caught=0, baited=0 },
            "setting "..place.." baited trap(s) near you"
    end
    local anchor = anchorFor(body, owner, true)
    if not anchor then return nil, "owner position unavailable" end
    local traps = trapsNear(anchor)
    if #traps == 0 then return nil, "no traps within thirty tiles of the base or you; try traps place" end
    return { owner=name, anchor=anchor, completed=0, caught=0, baited=0 },
        "checking "..#traps.." trap(s)"
end

local function placeUpdate(body, payload, runtime, now)
    if (payload.placed or 0) >= payload.place then
        return true, true, string.format("set %d baited trap(s)", payload.placed), "COMPLETE"
    end
    if not runtime.site then
        runtime.site = placeSite(body, payload.anchor, runtime)
        runtime.readyAt, runtime.siteAt = nil, now
        if not runtime.site then
            return true, (payload.placed or 0) > 0,
                string.format("set %d trap(s); no more good ground nearby", payload.placed or 0),
                (payload.placed or 0) > 0 and "COMPLETE" or "NO_TARGET"
        end
    end
    local square = runtime.site
    if now - runtime.siteAt > 45000 then
        runtime.tried[tile(square).x..":"..tile(square).y] = true
        runtime.site = nil
        return false
    end
    if not Support.work(body, runtime, square, now, 3000, "LOOT", "setting a trap") then return false end
    runtime.site, runtime.readyAt = nil, nil
    local p = tile(square)
    runtime.tried[p.x..":"..p.y] = true
    if not Life.Traps.siteValid(square) then return false end
    local trap, why = Life.Traps.place(body, square, playerFor(payload.owner), Life.TRAP_TYPE)
    if not trap then
        runtime.failures = (runtime.failures or 0) + 1
        if runtime.failures >= 3 then
            if (payload.placed or 0) > 0 then
                return true, true, string.format("set %d trap(s); %s", payload.placed, tostring(why)), "COMPLETE"
            end
            return true, false, why, "ENGINE_ERROR"
        end
        return false
    end
    payload.placed = (payload.placed or 0) + 1
    if bait(body, trap, payload.owner) then payload.baited = (payload.baited or 0) + 1 end
    return false
end

function Life.Traps.update(body, payload, runtime, now)
    if not playerFor(payload.owner) then return true, false, "owner logged out; trap run stopped", "INTERRUPTED" end
    if (payload.place or 0) > 0 then return placeUpdate(body, payload, runtime, now) end
    runtime.done = runtime.done or {}
    if not runtime.target then
        for _, entry in ipairs(trapsNear(payload.anchor)) do
            local key = entry.trap.x..":"..entry.trap.y..":"..entry.trap.z
            if not runtime.done[key] and needsVisit(entry.trap) then
                runtime.target, runtime.key, runtime.readyAt, runtime.targetAt = entry.trap, key, nil, now
                break
            end
        end
        if not runtime.target then
            return true, true, string.format("trap run done: %d catch(es) collected, %d trap(s) re-baited",
                payload.caught or 0, payload.baited or 0), "COMPLETE"
        end
    end
    local trap = runtime.target
    local square = World.square({ x=trap.x, y=trap.y, z=trap.z })
    if not square or now - runtime.targetAt > 60000 then
        runtime.done[runtime.key], runtime.target = true, nil
        return false
    end
    if not Support.work(body, runtime, square, now, 2500, "LOOT", "checking a trap") then return false end
    runtime.done[runtime.key], runtime.target, runtime.readyAt = true, nil, nil
    if type(trap.animal) == "table" and trap.animal.type then
        -- A live catch is dispatched: Goblin carries the native corpse/food item.
        -- The collector name never matches the trap owner, so the installed
        -- code skips its IsoPlayer-only addXp; the actor-inventory packet is
        -- suppressed because Build 42 rejects it for the square-less Goblin.
        trap.animal.canBeAlive = false
        local collector = trapper(body, "goblin:"..tostring(payload.owner))
        local send = rawget(_G, "sendAddItemToContainer")
        sendAddItemToContainer = function() end
        local ok, err = pcall(trap.removeAnimal, trap, collector)
        sendAddItemToContainer = send
        if ok then
            payload.caught = (payload.caught or 0) + 1
            print("[GoblinSurvivor] TRAP_COLLECT owner="..tostring(payload.owner).." at="..runtime.key)
        else
            print("[GoblinSurvivor] TRAP_ERROR "..tostring(err))
        end
    end
    if bait(body, trap, payload.owner) then payload.baited = (payload.baited or 0) + 1 end
    payload.completed = (payload.completed or 0) + 1
    return false
end

-- --------------------------------------------------------------- COOK

Life.Cook = {}
Life.COOK_TIMEOUT_MS = 900000
Life.CAMPFIRE_FUEL = 120 -- game minutes of conjured firewood
Life.POT_RECIPES = { soup="Soup", stew="Stew" }

local function isStove(object)
    return type(instanceof) == "function" and instanceof(object, "IsoStove")
end

local function rawFood(item)
    return select(2, call(item, "isCookable")) == true and select(2, call(item, "isCooked")) ~= true
        and select(2, call(item, "isBurnt")) ~= true
end

local function campfireSystem()
    local system = rawget(_G, "SCampfireSystem")
    return system and system.instance or nil
end

local function campfireSite(fire)
    local _, square = call(fire, "getSquare")
    local container = select(2, call(fire, "getContainer"))
    local object = select(2, call(fire, "getIsoObject"))
    if not square or not container or not object then return nil end
    return { kind="campfire", fire=fire, object=object, square=square, container=container }
end

-- Nearest heat source: a stove/oven/microwave, else a campfire.
local function siteKey(square) local p = tile(square); return p.x..":"..p.y..":"..p.z end

local function nearestHeat(body, anchor, radius, skip)
    skip = skip or {}
    local best, bestD
    for dx = -radius, radius do for dy = -radius, radius do
        local square = World.square({ x=anchor.x+dx, y=anchor.y+dy, z=anchor.z })
        if square then
            for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                local _, container = call(object, "getContainer")
                if isStove(object) and container and not skip[siteKey(square)] and Policy.access(body, object) then
                    local d = dx*dx + dy*dy
                    if not best or d < bestD then
                        best, bestD = { kind="stove", object=object, square=square, container=container }, d
                    end
                end
            end
        end
    end end
    if best then return best end
    local system = campfireSystem()
    if system and type(system.getLuaObjectCount) == "function" then
        local ok, total = pcall(system.getLuaObjectCount, system)
        for index = 1, (ok and total or 0) do
            local got, fire = pcall(system.getLuaObjectByIndex, system, index)
            if got and type(fire) == "table" and fire.z == anchor.z then
                local d = (fire.x - anchor.x)^2 + (fire.y - anchor.y)^2
                if d <= radius*radius and (not best or d < bestD) then
                    local site = campfireSite(fire)
                    if site and not skip[siteKey(site.square)] and Policy.access(body, site.object) then
                        best, bestD = site, d
                    end
                end
            end
        end
    end
    return best
end

-- Outdoor, free, floored square beside the owner for a new campfire.
local function campfireGround(body, anchor)
    for r = 1, 3 do
        for dx = -r, r do for dy = -r, r do
            if math.max(math.abs(dx), math.abs(dy)) == r then
                local square = World.square({ x=anchor.x+dx, y=anchor.y+dy, z=anchor.z })
                if square and select(2, call(square, "isOutside")) == true
                    and select(2, call(square, "isFree", false)) == true
                    and Policy.access(body, { getSquare=function() return square end }) then
                    local _, objects = call(square, "getObjects")
                    local _, n = call(objects, "size")
                    if (n or 0) <= 1 then return square end
                end
            end
        end end
    end
    return nil
end

local function heatOn(site)
    if site.kind == "stove" then
        return select(2, call(site.object, "Activated")) == true
    end
    return site.fire.isLit == true
end

-- Returns switchedOn, error.
local function lightHeat(site)
    if heatOn(site) then return false end
    if site.kind == "stove" then
        call(site.object, "Toggle")
        if not heatOn(site) then return false, "the stove has no power or fuel" end
        return true
    end
    -- Goblin brings his own firewood (conjured fuel, burned in the fire).
    if (tonumber(site.fire.fuelAmt) or 0) < Life.CAMPFIRE_FUEL then
        pcall(site.fire.addFuel, site.fire, Life.CAMPFIRE_FUEL)
    end
    pcall(site.fire.lightFire, site.fire)
    if not heatOn(site) then return false, "the campfire would not light" end
    return true
end

local function heatOff(site)
    if not heatOn(site) then return end
    if site.kind == "stove" then call(site.object, "Toggle")
    else pcall(site.fire.putOut, site.fire) end
end

local function potRecipe(name)
    local manager = rawget(_G, "ScriptManager")
    local instance = manager and manager.instance
    if not instance then return nil end
    for _, key in ipairs({ name, "Base."..name }) do
        local ok, recipe = pcall(function() return instance:getEvolvedRecipe(key) end)
        if ok and recipe then return recipe end
    end
    local _, list = call(instance, "getAllEvolvedRecipesList")
    for _, recipe in ipairs(World.values(list)) do
        if select(2, call(recipe, "getOriginalname")) == name
            or select(2, call(recipe, "getUntranslatedName")) == name then return recipe end
    end
    return nil
end

local function ingredientFor(recipe)
    return function(item)
        if select(2, call(item, "isRotten")) == true or select(2, call(item, "isBurnt")) == true then return false end
        local ok, entry = call(recipe, "getItemRecipe", item)
        return ok and entry ~= nil
    end
end

function Life.Cook.prepare(body, owner, request)
    local name, why = ownerOrder(body, owner, request)
    if not name then return nil, why end
    local dish = type(request) == "table" and type(request.dish) == "string" and string.lower(request.dish) or nil
    if dish == "food" then dish = nil end
    if dish and not Life.POT_RECIPES[dish] then return nil, "cook food, soup or stew" end
    local n = count(request, dish and 4 or 3, dish and 6 or 5)
    if not n then return nil, dish and "a pot takes 1 to 6 ingredients" or "cook 1 to 5 items per order" end
    local anchor = anchorFor(body, owner, false)
    if not anchor then return nil, "owner position unavailable" end
    if not nearestHeat(body, anchor, 10) and not (campfireSystem() and campfireGround(body, anchor)) then
        return nil, "no stove or campfire within ten tiles, and no open ground here for a campfire"
    end
    local accept = rawFood
    if dish then
        local recipe = potRecipe(Life.POT_RECIPES[dish])
        if not recipe then return nil, "the "..dish.." recipe is not installed" end
        accept = ingredientFor(recipe)
    end
    local carried = 0
    for _, item in ipairs(World.items(World.inventory(body))) do
        if accept(item) and Transfer.movable(body, item) then carried = carried + 1 end
    end
    if carried == 0 and #World.sources(anchor, 8, accept, body) == 0 then
        return nil, dish and ("no "..dish.." ingredients near you") or "no raw food to cook near you"
    end
    return { owner=name, anchor=anchor, count=n, dish=dish, completed=0, phase="gather", cooking={} },
        dish and ("making a pot of "..dish.." with up to "..n.." ingredient(s)") or ("cooking up to "..n.." item(s)")
end

-- Fills a fresh result pot inside the heat container with the ingredients,
-- through the installed EvolvedRecipe.addItem. The pot and water are Goblin's
-- own (conjured); the ingredients are real food. Pot and ingredients sit in
-- the world container, so native ItemStats packets have a valid address.
local function fillPot(body, site, recipe, ingredients)
    local ok, resultType = call(recipe, "getFullResultItem")
    if not ok or type(resultType) ~= "string" or type(instanceItem) ~= "function" then
        return nil, "the recipe has no result pot"
    end
    local made, pot = pcall(instanceItem, resultType)
    if not made or not pot then return nil, "could not make the pot" end
    call(pot, "setIsCookable", true)
    local added, value = call(site.container, "AddItem", pot)
    if not added or value ~= pot then return nil, "the heat source would not take the pot" end
    if type(sendAddItemToContainer) == "function" then pcall(sendAddItemToContainer, site.container, pot) end
    local used = 0
    for _, item in ipairs(ingredients) do
        if Transfer.deposit(body, item, site.container) then
            local fine, err = pcall(recipe.addItem, recipe, pot, item, body)
            if not fine then print("[GoblinSurvivor] POT_INGREDIENT_ERROR "..tostring(err)) end
            local gone = World.containsExact(site.container, item) == false
            if fine or gone then used = used + 1 end
            if not gone then
                -- Partly used or refused: take it back as cargo.
                Transfer.pickup(body, { square=site.square, object=site.object, container=site.container, item=item })
            end
        end
    end
    if used == 0 then
        call(site.container, "DoRemoveItem", pot)
        if type(sendRemoveItemFromContainer) == "function" then
            pcall(sendRemoveItemFromContainer, site.container, pot)
        end
        return nil, "none of the ingredients went into the pot"
    end
    return pot, used
end

function Life.Cook.update(body, payload, runtime, now)
    if not playerFor(payload.owner) then return true, false, "owner logged out; cooking stopped", "INTERRUPTED" end
    runtime.skipped = runtime.skipped or {}
    runtime.startedAt = runtime.startedAt or now
    local recipe = payload.dish and potRecipe(Life.POT_RECIPES[payload.dish]) or nil
    if payload.dish and not recipe then return true, false, "the recipe is gone", "UNSUPPORTED" end
    local accept = recipe and ingredientFor(recipe) or rawFood
    runtime.badSites = runtime.badSites or {}
    local site = runtime.site or nearestHeat(body, payload.anchor, 10, runtime.badSites)
    if site and site ~= runtime.site then runtime.siteAt = now end
    if not site and payload.phase == "gather" and not runtime.builtFire then
        -- No stove or fire: Goblin builds a campfire beside the owner.
        local ground = campfireGround(body, payload.anchor)
        local system = campfireSystem()
        if ground and system then
            if not Support.work(body, runtime, ground, now, 3000, "BUILD", "building a campfire") then return false end
            runtime.readyAt = nil
            local ok, fire = pcall(system.addCampfire, system, ground)
            site = ok and type(fire) == "table" and campfireSite(fire) or nil
            if site then
                runtime.builtFire = true
                print("[GoblinSurvivor] CAMPFIRE_BUILT owner="..tostring(payload.owner))
            end
        end
        if not site then return true, false, "could not build a campfire here", "BLOCKED" end
    end
    if not site then return true, false, "the stove or fire is gone", "TARGET_CHANGED" end
    runtime.site = site
    if payload.phase == "gather" then
        local inventory = World.inventory(body)
        local held = {}
        for _, item in ipairs(World.items(inventory)) do
            if accept(item) and Transfer.movable(body, item) then held[#held+1] = item end
        end
        runtime.gatherStarted = runtime.gatherStarted or now
        if #held < payload.count and now - runtime.gatherStarted < 60000 then
            if runtime.supply and now - (runtime.supplyAt or now) > 5000 then
                Support.status(body, "fetching "..(payload.dish and (payload.dish.." ingredients") or "raw food"))
            end
            local notCarried = function(item)
                return accept(item) and World.containsExact(inventory, item) ~= true
            end
            if runtime.supply or #World.sources(payload.anchor, 8, notCarried, body) > 0 then
                Support.supply(body, runtime, payload.anchor, notCarried, now,
                    payload.dish and (payload.dish.." ingredients") or "raw food")
                return false
            end
        end
        if #held == 0 then
            return true, false, payload.dish and "no ingredients left" or "no raw food left to cook", "MISSING_MATERIAL"
        end
        local label = site.kind == "campfire" and "loading the campfire" or "loading the stove"
        runtime.loadAt = runtime.loadAt or now
        if not Support.work(body, runtime, site.square, now, 1500, "CRAFT", label) then
            if now - runtime.loadAt > 45000 then
                -- Unreachable heat source: try the next one, or build a fire.
                print("[GoblinSurvivor] COOK_SITE_UNREACHABLE owner="..tostring(payload.owner).." kind="..site.kind
                    .." at="..siteKey(site.square))
                runtime.badSites[siteKey(site.square)] = true
                runtime.site, runtime.loadAt, runtime.readyAt = nil, nil, nil
                runtime.tries = (runtime.tries or 0) + 1
                if runtime.tries >= 3 then
                    return true, false, "I can't reach a stove or fire from here", "NO_PATH"
                end
            end
            return false
        end
        runtime.readyAt = nil
        local switched, err = lightHeat(site)
        if err then return true, false, err, "BLOCKED" end
        runtime.switchedOn = switched
        payload.cooking = {}
        -- Items already on the heat; anything new that appears later is ours
        -- (the engine replaces some foods on cooking, e.g. a soup pot).
        payload.baseline = {}
        for _, item in ipairs(World.items(site.container)) do
            local id = Transfer.itemId(item)
            if id then payload.baseline[#payload.baseline + 1] = id end
        end
        local chosen = {}
        for i = 1, math.min(#held, payload.count) do chosen[i] = held[i] end
        if recipe then
            local pot, used = fillPot(body, site, recipe, chosen)
            if not pot then
                if runtime.switchedOn then heatOff(site) end
                return true, false, used, "ENGINE_ERROR"
            end
            payload.ingredients = used
            payload.cooking = { Transfer.itemId(pot) }
            print("[GoblinSurvivor] POT_FILLED owner="..tostring(payload.owner).." dish="..payload.dish
                .." ingredients="..tostring(used))
        else
            for _, item in ipairs(chosen) do
                if Transfer.deposit(body, item, site.container) then
                    payload.cooking[#payload.cooking+1] = Transfer.itemId(item)
                end
            end
        end
        if #payload.cooking == 0 then return true, false, "the heat source would not take the food", "BLOCKED" end
        payload.phase = "cooking"
        return false
    end
    -- Cooking: take each item out once cooked (or burnt) and keep watch.
    Support.status(body, site.kind == "campfire" and "watching the fire" or "watching the stove")
    if now - runtime.startedAt > Life.COOK_TIMEOUT_MS then
        if runtime.switchedOn or runtime.builtFire then heatOff(site) end
        return true, false, "cooking took too long; I left the rest on the heat", "TIMEOUT"
    end
    if site.kind == "campfire" and not heatOn(site) then lightHeat(site) end
    local remaining = {}
    for _, id in ipairs(payload.cooking or {}) do
        local item = Transfer.findById(site.container, id)
        if item and (select(2, call(item, "isCooked")) == true or select(2, call(item, "isBurnt")) == true) then
            if World.approach(body, site.square, now) then
                local moved = Transfer.pickup(body, { square=site.square, object=site.object,
                    container=site.container, item=item })
                if moved then payload.completed = (payload.completed or 0) + 1 else remaining[#remaining+1] = id end
            else
                remaining[#remaining+1] = id
            end
        elseif item then
            remaining[#remaining+1] = id
        else
            payload.replaced = (payload.replaced or 0) + 1
        end
    end
    -- A tracked item that vanished was replaced by its cooked form: collect
    -- new cooked items that were not on the heat before we loaded it.
    if (payload.replaced or 0) > 0 then
        local known = {}
        for _, id in ipairs(payload.baseline or {}) do known[id] = true end
        for _, id in ipairs(remaining) do known[id] = true end
        for _, item in ipairs(World.items(site.container)) do
            local id = Transfer.itemId(item)
            if payload.replaced > 0 and id and not known[id]
                and (select(2, call(item, "isCooked")) == true or select(2, call(item, "isBurnt")) == true) then
                if World.approach(body, site.square, now) and Transfer.pickup(body, { square=site.square,
                    object=site.object, container=site.container, item=item }) then
                    payload.completed = (payload.completed or 0) + 1
                    payload.replaced = payload.replaced - 1
                end
            end
        end
        if payload.replaced > 0 then
            runtime.replacedSince = runtime.replacedSince or now
            -- Give the engine a moment to place the replacement item.
            if now - runtime.replacedSince < 10000 then return false end
        end
    end
    payload.cooking = remaining
    if #remaining > 0 then return false end
    if runtime.switchedOn or runtime.builtFire then heatOff(site) end
    print("[GoblinSurvivor] COOK owner="..tostring(payload.owner).." dish="..tostring(payload.dish or "food")
        .." cooked="..tostring(payload.completed).." heat="..site.kind)
    if (payload.completed or 0) == 0 then
        return true, false, "the food left the heat before I could take it out", "TARGET_CHANGED"
    end
    local what = payload.dish and ("a pot of "..payload.dish) or (payload.completed.." item(s)")
    return true, true, "cooked "..what.."; I will bring it home", "COMPLETE"
end

function Life.Cook.clear(body) end

return Life
