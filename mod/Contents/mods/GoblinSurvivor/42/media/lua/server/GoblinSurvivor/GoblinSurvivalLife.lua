-- Milestone 5 survival life: foraging, trap runs and stove cooking.
--
-- FORAGE     : the installed forageSystem (shared/Foraging) rolls a real item
--              for the forage zone and month at each spot Goblin searches.
--              Finds are ordinary cargo; Goblin's next delivery takes them to
--              the base (never conjured, never quarantined).
-- CHECK_TRAPS: STrapSystem trap records within range of the base/owner.
--              Goblin empties caught animals with the installed
--              STrapGlobalObject:removeAnimal (a live catch is dispatched, so
--              the result is the native corpse/food item) and re-baits empty
--              traps with his own conjured bait, owned by his player.
-- COOK       : raw cookable food from nearby storage goes into a loaded
--              IsoStove container that has heat (Goblin switches it on and
--              back off). The engine cooks it; Goblin takes each item out once
--              isCooked() and before it burns, then delivers it with his cargo.
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
    local p = World.point(square)
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
                return true, (payload.completed or 0) > 0, "found no more forageable ground nearby", "NO_TARGET"
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
            return true, (payload.completed or 0) > 0, "the ground here is picked clean", "NO_TARGET"
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
Life.TRAP_BAIT = "Base.Carrots"

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

function Life.Traps.prepare(body, owner, request)
    local name, why = ownerOrder(body, owner, request)
    if not name then return nil, why end
    local anchor = anchorFor(body, owner, true)
    if not anchor then return nil, "owner position unavailable" end
    if not trapSystem() then return nil, "the installed trap system is not loaded" end
    local traps = trapsNear(anchor)
    if #traps == 0 then return nil, "no traps within thirty tiles of the base or you" end
    return { owner=name, anchor=anchor, completed=0, caught=0, baited=0 },
        "checking "..#traps.." trap(s)"
end

function Life.Traps.update(body, payload, runtime, now)
    if not playerFor(payload.owner) then return true, false, "owner logged out; trap run stopped", "INTERRUPTED" end
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
    local actor = trapper(body, payload.owner)
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
    if not trap.bait and not trap.destroyed then
        local Provision = require("GoblinSurvivor/GoblinProvision")
        local created = Provision.enabled() and Provision.create(body, Life.TRAP_BAIT, 1, "trap bait") or nil
        local bait = created and created[1]
        if bait then
            local ok = pcall(trap.addBait, trap, Life.TRAP_BAIT, 0, -0.05, actor)
            call(World.inventory(body), "DoRemoveItem", bait)
            if ok and trap.bait then payload.baited = (payload.baited or 0) + 1 end
        end
    end
    payload.completed = (payload.completed or 0) + 1
    return false
end

-- --------------------------------------------------------------- COOK

Life.Cook = {}
Life.COOK_TIMEOUT_MS = 900000

local function isStove(object)
    return type(instanceof) == "function" and instanceof(object, "IsoStove")
end

local function rawFood(item)
    return select(2, call(item, "isCookable")) == true and select(2, call(item, "isCooked")) ~= true
        and select(2, call(item, "isBurnt")) ~= true
end

local function nearestStove(body, anchor, radius)
    local best, bestD
    for dx = -radius, radius do for dy = -radius, radius do
        local square = World.square({ x=anchor.x+dx, y=anchor.y+dy, z=anchor.z })
        if square then
            for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                local _, container = call(object, "getContainer")
                if isStove(object) and container and Policy.access(body, object) then
                    local d = dx*dx + dy*dy
                    if not best or d < bestD then best, bestD = { stove=object, square=square, container=container }, d end
                end
            end
        end
    end end
    return best
end

function Life.Cook.prepare(body, owner, request)
    local name, why = ownerOrder(body, owner, request)
    if not name then return nil, why end
    local n = count(request, 3, 5)
    if not n then return nil, "cook 1 to 5 items per order" end
    local anchor = anchorFor(body, owner, false)
    if not anchor then return nil, "owner position unavailable" end
    if not nearestStove(body, anchor, 10) then return nil, "no stove or oven within ten tiles of you" end
    local carried = 0
    for _, item in ipairs(World.items(World.inventory(body))) do if rawFood(item) then carried = carried + 1 end end
    if carried == 0 and #World.sources(anchor, 8, rawFood, body) == 0 then
        return nil, "no raw food to cook near you"
    end
    return { owner=name, anchor=anchor, count=n, completed=0, phase="gather", cooking={} },
        "cooking up to "..n.." item(s)"
end

local function stoveHot(stove)
    return select(2, call(stove, "Activated")) == true
end

function Life.Cook.update(body, payload, runtime, now)
    if not playerFor(payload.owner) then return true, false, "owner logged out; cooking stopped", "INTERRUPTED" end
    runtime.skipped = runtime.skipped or {}
    runtime.startedAt = runtime.startedAt or now
    local site = runtime.site or nearestStove(body, payload.anchor, 10)
    if not site then return true, false, "the stove is gone", "TARGET_CHANGED" end
    runtime.site = site
    if payload.phase == "gather" then
        local inventory = World.inventory(body)
        local held = {}
        for _, item in ipairs(World.items(inventory)) do
            if rawFood(item) and Transfer.movable(body, item) then held[#held+1] = item end
        end
        runtime.gatherStarted = runtime.gatherStarted or now
        if #held < payload.count and now - runtime.gatherStarted < 60000 then
            local notCarried = function(item)
                return rawFood(item) and World.containsExact(inventory, item) ~= true
            end
            if runtime.supply or #World.sources(payload.anchor, 8, notCarried, body) > 0 then
                Support.supply(body, runtime, payload.anchor, notCarried, now, "raw food")
                return false
            end
        end
        if #held == 0 then return true, false, "no raw food left to cook", "MISSING_MATERIAL" end
        if not Support.work(body, runtime, site.square, now, 1500, "CRAFT", "loading the stove") then return false end
        runtime.readyAt = nil
        if not stoveHot(site.stove) then
            call(site.stove, "Toggle")
            runtime.switchedOn = stoveHot(site.stove)
            if not runtime.switchedOn then
                return true, false, "the stove has no power or fuel", "BLOCKED"
            end
        end
        payload.cooking = {}
        for i = 1, math.min(#held, payload.count) do
            local ok = Transfer.deposit(body, held[i], site.container)
            if ok then payload.cooking[#payload.cooking+1] = Transfer.itemId(held[i]) end
        end
        if #payload.cooking == 0 then return true, false, "the stove would not take the food", "BLOCKED" end
        payload.phase = "cooking"
        return false
    end
    -- Cooking: take each item out once cooked (or burnt) and keep watch.
    Support.status(body, "watching the stove")
    if now - runtime.startedAt > Life.COOK_TIMEOUT_MS then
        return true, (payload.completed or 0) > 0, "cooking took too long; I left the rest in the stove", "TIMEOUT"
    end
    local remaining = {}
    for _, id in ipairs(payload.cooking or {}) do
        local item = Transfer.findById(site.container, id)
        if item and (select(2, call(item, "isCooked")) == true or select(2, call(item, "isBurnt")) == true) then
            local square = site.square
            if World.approach(body, square, now) then
                local moved = Transfer.pickup(body, { square=square, object=site.stove,
                    container=site.container, item=item })
                if moved then payload.completed = (payload.completed or 0) + 1 else remaining[#remaining+1] = id end
            else
                remaining[#remaining+1] = id
            end
        elseif item then
            remaining[#remaining+1] = id
        end
    end
    payload.cooking = remaining
    if #remaining > 0 then return false end
    if runtime.switchedOn and stoveHot(site.stove) then call(site.stove, "Toggle") end
    print("[GoblinSurvivor] COOK owner="..tostring(payload.owner).." cooked="..tostring(payload.completed))
    return true, (payload.completed or 0) > 0,
        "cooked "..(payload.completed or 0).." item(s); I will bring them home", "COMPLETE"
end

function Life.Cook.clear(body) end

return Life
