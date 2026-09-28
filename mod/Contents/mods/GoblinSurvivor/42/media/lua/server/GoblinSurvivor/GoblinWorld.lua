-- Engine-facing inventory and reach checks shared by looting and construction.
local Body = require("GoblinSurvivor/GoblinBody")
local Config = require("GoblinSurvivor/Config")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local Policy = require("GoblinSurvivor/GoblinAccessPolicy")
local World = {
    approaches = setmetatable({}, { __mode = "k" }),
    pendingMaterials = setmetatable({}, { __mode = "k" })
}

function World.call(object, method, ...)
    if object == nil then return false, nil end
    local ok, member = pcall(function() return object[method] end)
    if not ok or type(member) ~= "function" then return false, nil end
    return pcall(member, object, ...)
end
local call = World.call

function World.values(list)
    local result = {}
    local _, n = call(list, "size")
    n = tonumber(n) or 0
    if n <= 0 then return result end
    local indexed, first = call(list, "get", 0)
    if indexed then
        if first then result[#result+1] = first end
        for i = 1, n - 1 do
            local _, value = call(list, "get", i)
            if value then result[#result+1] = value end
        end
        return result
    end
    -- IsoCell.getVehicles() is a java.util.Set in the installed game build.
    -- Unlike inventory ArrayLists it has size(), but no indexed get().
    local _, iterator = call(list, "iterator")
    for _ = 1, n do
        local checked, hasNext = call(iterator, "hasNext")
        if not checked or hasNext ~= true then break end
        local got, value = call(iterator, "next")
        if not got then break end
        if value then result[#result+1] = value end
    end
    return result
end

function World.inventory(body) return select(2, call(body, "getInventory")) end
function World.items(container) return World.values(select(2, call(container, "getItems"))) end
function World.fullType(item) return select(2, call(item, "getFullType")) end
function World.square(point)
    if not point then return nil end
    return getCell():getGridSquare(math.floor(point.x), math.floor(point.y), math.floor(point.z))
end
function World.point(square)
    return { x = square:getX()+0.5, y = square:getY()+0.5, z = square:getZ() }
end

local function edgeClear(from, target)
    local checked, blocked = call(from, "isBlockedTo", target)
    if not checked or blocked ~= false then return false end
    local dx, dy = target:getX() - from:getX(), target:getY() - from:getY()
    if math.abs(dx) ~= 1 or math.abs(dy) ~= 1 then return true end
    -- A diagonal edge alone can appear clear even when both cardinal ways
    -- around a corner cross a wall. At least one two-edge route must exist.
    local cell = getCell()
    if not cell then return false end
    for _, offset in ipairs({ { dx, 0 }, { 0, dy } }) do
        local side = cell:getGridSquare(from:getX() + offset[1], from:getY() + offset[2], from:getZ())
        local firstOK, firstBlocked = call(from, "isBlockedTo", side)
        local secondOK, secondBlocked = call(side, "isBlockedTo", target)
        if side and firstOK and firstBlocked == false and secondOK and secondBlocked == false then
            return true
        end
    end
    return false
end

function World.reachable(body, square)
    local here = World.square(Body.position(body))
    if not here or not square or here:getZ() ~= square:getZ() then return false end
    if math.abs(here:getX()-square:getX()) > 1 or math.abs(here:getY()-square:getY()) > 1 then return false end
    if here == square then return true end
    return edgeClear(here, square)
end

local function squareOccupied(square, body)
    local gotList, objects = call(square, "getMovingObjects")
    local gotSize, size = call(objects, "size")
    if not gotList or not objects or not gotSize or type(size) ~= "number"
        or size ~= math.floor(size) or size < 0 or size > 10000 then return true end
    for index = 0, size - 1 do
        local gotObject, object = call(objects, "get", index)
        if not gotObject or not object or object ~= body then return true end
    end
    return false
end

local function squareDoorway(square)
    for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
        local _, door = call(object, "isDoor")
        local _, frame = call(object, "isDoorFrame")
        if door == true or frame == true then return true end
    end
    return false
end

local function targetKey(square)
    return table.concat({ square:getX(), square:getY(), square:getZ() }, ":")
end

local function candidates(body, target, ring, now)
    local here, result = Body.position(body), {}
    for dx = -ring, ring do
        for dy = -ring, ring do
            if ring == 0 or math.max(math.abs(dx), math.abs(dy)) == ring then
                local square = getCell():getGridSquare(target:getX()+dx, target:getY()+dy, target:getZ())
                local freeOK, free = call(square, "isFree", false)
                local fireOK, fire = call(square, "haveFire")
                local clear = ring > 1 or square == target
                if ring == 1 and square ~= target then
                    clear = edgeClear(square, target)
                end
                if square and freeOK and free == true and fireOK and fire == false and clear
                    and not squareOccupied(square, body) then
                    local point = World.point(square)
                    local key = targetKey(square)
                    if not Motion.isBlacklisted(body, key, now, "approach") then
                        local distance = (point.x-here.x)^2 + (point.y-here.y)^2
                        local score = distance + ring * 3 + (squareDoorway(square) and 15 or 0)
                        result[#result+1] = { square = square, point = point, score = score,
                            interaction_target = target, ring = ring, key = key,
                            reason = ring > 1 and "radius-2 staging approach" or "interaction approach" }
                    end
                end
            end
        end
    end
    table.sort(result, function(a,b) return a.score < b.score end)
    return result
end

function World.approachCandidate(body, square, now, allowStaging)
    if not square then return nil, "target unloaded" end
    for ring = 0, 1 do
        local found = candidates(body, square, ring, now)
        if found[1] then return found[1] end
    end
    if allowStaging ~= false then
        local found = candidates(body, square, 2, now)
        if found[1] then return found[1] end
    end
    return nil, "no accessible work square"
end

local function candidateValid(body, target, candidate, now)
    if type(candidate)~="table" or not candidate.square or not candidate.point then return false end
    local square=getCell():getGridSquare(candidate.square:getX(),candidate.square:getY(),candidate.square:getZ())
    if square~=candidate.square then return false end
    local freeOK,free=call(square,"isFree",false)
    local fireOK,fire=call(square,"haveFire")
    if not freeOK or free~=true or not fireOK or fire~=false or squareOccupied(square,body)
        or Motion.isBlacklisted(body,candidate.key,now,"approach") then return false end
    if candidate.ring==1 and square~=target then
        if not edgeClear(square,target) then return false end
    end
    return true
end

function World.approach(body, square, now)
    if not square then return false, "target unloaded" end
    if World.reachable(body, square) then
        Movement.clear(body)
        World.approaches[body] = nil
        return true, "arrived"
    end
    now = now or (type(getTimestampMs) == "function" and getTimestampMs() or 0)
    local state = World.approaches[body]
    local key = targetKey(square)
    if not state or state.target ~= key then state = { target = key }; World.approaches[body] = state end
    if state.staging then
        local point = Body.position(body)
        if Motion.distance(point, state.staging) <= 0.6 then
            state.staged = true
            state.staging = nil
            state.chosen = nil
            Motion.clearBlacklistKind(body, "approach")
            Movement.clear(body)
        end
    end
    if state.chosen and not candidateValid(body,square,state.chosen,now) then
        state.chosen,state.staging,state.progressPoint,state.progressAt=nil,nil,nil,nil
    end
    -- Keep one accepted approach while it remains valid. Re-scoring from the
    -- actor's new position every tick makes the best radius-2 point orbit the
    -- target and causes a client-owned actor to chase a moving destination.
    local candidate, reason = state.chosen, nil
    if not candidate then
        candidate,reason=World.approachCandidate(body,square,now,not state.staged)
        state.chosen=candidate
        state.progressPoint,state.progressAt=Body.position(body),now
    end
    if not candidate then return false, reason end
    -- On a dedicated server the nearby client often owns this IsoZombie's
    -- native path. Motion.drive then reports "delegated", so only the server's
    -- observed position can prove that the chosen work approach is advancing.
    -- Blacklist a stalled square and let the next tick select an alternate.
    if not Motion.controls(body) then
        local current=Body.position(body)
        if current and state.progressPoint and Motion.distance(current,state.progressPoint)>=0.25 then
            state.progressPoint,state.progressAt=current,now
        elseif state.progressAt and now-state.progressAt>=2*Config.stuckTimeoutSeconds*1000 then
            Motion.blacklist(body,candidate.key,"delegated work approach made no progress",now,"approach")
            state.chosen,state.staging,state.progressPoint,state.progressAt=nil,nil,nil,nil
            Movement.clear(body)
            return false,"retrying alternate work approach"
        end
    end
    if candidate.ring > 1 then state.staging = candidate.point else state.staging = nil; state.staged = false end
    local nearest = candidate.point
    nearest.radius = 0.45
    nearest.approach_type = candidate.ring > 1 and "work_staging" or "work_approach"
    nearest.approach_ring = candidate.ring
    nearest.goal_key = candidate.key
    nearest.blacklist_kind = "approach"
    local active = Movement.snapshot(body)
    local goal = active and active.goal
    local ok, detail
    if not goal or goal.x ~= nearest.x or goal.y ~= nearest.y or goal.z ~= nearest.z then
        ok, detail = Movement.command(body, "MOVE_TO", nearest)
    else
        ok, detail = Movement.update(body, now)
    end
    if not ok then
        if detail == "native path rejected" or detail == "no progress after native repath"
            or detail == "temporarily blacklisted route" then
            Motion.blacklist(body, candidate.key, detail, now, "approach")
            state.chosen, state.staging = nil, nil
            return false, "retrying alternate work approach"
        end
        return false, detail or "work approach unavailable"
    end
    return false, candidate.reason == "radius-2 staging approach"
        and "walking to alternate work approach" or "walking to supplies/work"
end

function World.containerAccessible(body, object)
    if not object then return false end
    -- Installed ISInventoryPage uses this native check for IsoThumpable
    -- containers. It respects combination locks and actual carried padlock
    -- keys without consuming a key or removing the lock. Its server path
    -- accepts IsoGameCharacter (including our managed IsoZombie).
    local inspected, method=pcall(function() return object.isLockedToCharacter end)
    if not inspected then return false end
    if type(method)=="function" then
        if not body then return false end
        local ok,locked=pcall(method,object,body)
        return ok and locked==false
    end
    inspected,method=pcall(function() return object.isLocked end)
    if not inspected then return false end
    if type(method)=="function" then
        local ok,locked=pcall(method,object)
        return ok and locked==false
    end
    return true -- Ordinary world containers have no native lock interface.
end

-- Items on one square (floor and accessible containers) accepted by accept.
local function squareSources(square, accept, body, found)
    local allowed = not body or Policy.access(body, { getSquare = function() return square end })
    if not allowed then return end
    for _, object in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
        local _, item = call(object, "getItem")
        if item and accept(item) then
            found[#found+1]={square=square,world=object,item=item}
        end
    end
    for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
        local _, container = call(object, "getContainer")
        if container and World.containerAccessible(body,object) then
            for _, item in ipairs(World.items(container)) do
                if accept(item) then
                    found[#found+1]={square=square,object=object,container=container,item=item}
                end
            end
        end
    end
end

local function nearestFirst(found, center)
    table.sort(found, function(a,b)
        local pa,pb=World.point(a.square),World.point(b.square)
        return (pa.x-center.x)^2+(pa.y-center.y)^2 < (pb.x-center.x)^2+(pb.y-center.y)^2
    end)
    return found
end

function World.sources(center, radius, accept, body)
    local found = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = World.square({x=center.x+dx,y=center.y+dy,z=center.z})
            if square then squareSources(square, accept, body, found) end
        end
    end
    return nearestFirst(found, center)
end

-- Goblin's search range in tiles (Config.goblinRange, default 150).
function World.range()
    local ok, Config = pcall(require, "GoblinSurvivor/Config")
    return math.floor(ok and tonumber(Config.goblinRange) or 150)
end

-- Offset of the i-th square (0-based) on the square ring of radius r.
function World.ringOffset(r, i)
    if r == 0 then return 0, 0 end
    local side, pos = math.floor(i / (2 * r)), i % (2 * r)
    if side == 0 then return -r + pos, -r end
    if side == 1 then return r, -r + pos end
    if side == 2 then return r - pos, r end
    return -r, r - pos
end

World.BAND = 4 -- rings finished before nearest results are handed back

-- Visit squares ring by ring outward from center up to maxRadius; visit
-- returns true to stop once the current band of rings is finished (so the
-- nearest hits are complete). state (optional) makes it resumable: at most
-- budget squares per call, returning false while more work remains.
function World.rings(center, maxRadius, visit, state, budget)
    state = state or {}
    state.r, state.i = state.r or 0, state.i or 0
    budget = budget or math.huge
    local cx, cy, cz = math.floor(center.x), math.floor(center.y), math.floor(center.z)
    while state.r <= maxRadius do
        local r = state.r
        local perimeter = r == 0 and 1 or 8 * r
        while state.i < perimeter do
            local dx, dy = World.ringOffset(r, state.i)
            state.i = state.i + 1
            local square = World.square({x=cx+dx, y=cy+dy, z=cz})
            if square and visit(square, r, dx, dy) then state.hit = true end
            budget = budget - 1
            if budget <= 0 and state.i < perimeter then return false end
        end
        state.r, state.i = r + 1, 0
        if state.hit and (state.r % World.BAND == 0) then state.done = true; return true end
        if budget <= 0 then return false end
    end
    state.done = true
    return true
end

-- Nearest item sources out to maxRadius (default World.range()). With a state
-- table the search is spread over calls: returns nil,false while searching,
-- then the nearest band's sources (possibly empty) and true.
function World.search(center, maxRadius, accept, body, state, budget)
    maxRadius = maxRadius or World.range()
    local found = state and state.found or {}
    if state then state.found = found end
    local skip = state and state.skipSquares
    local finished = World.rings(center, maxRadius, function(square)
        if skip and skip[square] then return false end
        local before = #found
        squareSources(square, accept, body, found)
        return #found > before
    end, state, budget)
    if not finished then return nil, false end
    return nearestFirst(found, center), true
end

-- One-shot nearest search (stops at the first band with a hit).
function World.sourcesNear(center, accept, body, maxRadius)
    local found = World.search(center, maxRadius, accept, body)
    return found or {}
end

-- sourcesNear for code that asks every tick: the wide search runs at most
-- every 10 s per cache table (kept in the job runtime).
function World.cachedNear(cache, center, accept, body, maxRadius)
    if type(cache) ~= "table" then return World.sourcesNear(center, accept, body, maxRadius) end
    local now = type(getTimestampMs) == "function" and getTimestampMs() or 0
    if cache.list and now < (cache.at or 0) + 10000 then
        local live = {}
        for _, source in ipairs(cache.list) do
            if source.item and accept(source.item) then live[#live+1] = source end
        end
        return live
    end
    cache.list, cache.at = World.sourcesNear(center, accept, body, maxRadius), now
    return cache.list
end

function World.has(container, item)
    for _, candidate in ipairs(World.items(container)) do if candidate == item then return true end end
    return false
end

-- Unlike has(), this distinguishes an absent item from an unreadable list.
-- Transfer decisions must never use a failed read as proof of absence.
function World.containsExact(container, item)
    local native, present = call(container, "contains", item)
    if native and type(present) == "boolean" then return present end
    local gotItems, items = call(container, "getItems")
    local gotSize, size = call(items, "size")
    if not gotItems or not items or not gotSize or type(size) ~= "number"
        or size ~= math.floor(size) or size < 0 or size > 10000 then return nil end
    local found = false
    for index = 0, size-1 do
        local gotItem, current = call(items, "get", index)
        if not gotItem or not current then return nil end
        if current == item then found = true end
    end
    return found
end

function World.take(body, source)
    if not World.reachable(body, source.square) then return false end
    local target = source.container and source.object or source.world
    if not target or not Policy.access(body,
        { getSquare = function() return source.square end }) then return false end
    local listMethod = source.container and "getObjects" or "getWorldObjects"
    local present = false
    for _, object in ipairs(World.values(select(2,call(source.square,listMethod)))) do
        if object == target then present = true; break end
    end
    if not present then return false end
    if source.container then
        if not World.containerAccessible(body,target) then return false end
        local okContainer, liveContainer = call(target,"getContainer")
        if not okContainer or liveContainer ~= source.container then return false end
    end
    local inv, item = World.inventory(body), source.item
    local roomOK, room = call(inv, "hasRoomFor", body, item)
    if not roomOK or room ~= true then return false end
    if source.container then
        if World.containsExact(source.container, item) ~= true then return false end
        local removed = call(source.container, "Remove", item)
        if not removed or World.containsExact(source.container,item) ~= false then return false end
    else
        local _, current = call(source.world, "getSquare")
        if current ~= source.square then return false end
    end
    local added, value = call(inv, "AddItem", item)
    local arrived = World.containsExact(inv, item)
    if not added or value == nil or value == false or arrived ~= true then
        if source.container and arrived == false
            and World.containsExact(source.container,item) == false then
            call(source.container, "AddItem", item)
        end
        return false
    end
    local sourceSynced = true
    if source.container then
        sourceSynced = type(sendRemoveItemFromContainer) == "function"
            and pcall(sendRemoveItemFromContainer, source.container, item)
    else
        source.square:transmitRemoveItemFromSquare(source.world)
        source.world:removeFromWorld()
        source.world:removeFromSquare()
        item:setWorldItem(nil)
    end
    -- A managed IsoZombie inventory cannot be addressed by Build 42's
    -- AddInventoryItemToContainer packet (ContainerID.set needs a world
    -- object square). Keep custody server-side; only the world source packet
    -- is sent here, and the eventual world destination is synchronized.
    return sourceSynced
end

function World.materials(body, requirements)
    local selected, remaining = {}, {}
    for kind,count in pairs(requirements) do remaining[kind]=count end
    for _, item in ipairs(World.items(World.inventory(body))) do
        local kind = World.fullType(item)
        if remaining[kind] and remaining[kind]>0 then
            selected[#selected+1]=item
            remaining[kind]=remaining[kind]-1
        end
    end
    for kind,count in pairs(remaining) do if count>0 then return nil, kind end end
    return selected
end

-- Reserve all materials first; the caller restores them if the world mutation fails.
function World.reserve(body, selected)
    local pending = World.pendingMaterials[body]
    if pending and not World.refund(body,pending) then return false end
    local inv = World.inventory(body)
    for _, item in ipairs(selected) do
        if World.containsExact(inv,item) ~= true then return false end
    end
    for _, item in ipairs(selected) do
        local removeOK = call(inv,"Remove",item)
        local present = World.containsExact(inv,item)
        if not removeOK or present ~= false then
            World.refund(body,selected)
            return false
        end
    end
    return true
end
function World.refund(body, selected)
    local inv = World.inventory(body)
    local pending = World.pendingMaterials[body]
    local all, seen = {}, {}
    for _, group in ipairs({pending or {},selected}) do
        for _, item in ipairs(group) do
            if not seen[item] then seen[item] = true; all[#all+1] = item end
        end
    end
    local restored = true
    for _, item in ipairs(all) do
        local present = World.containsExact(inv,item)
        if present == false then
            local added, value = call(inv,"AddItem",item)
            if not added or value ~= item or World.containsExact(inv,item) ~= true then
                restored = false
            end
        elseif present ~= true then
            restored = false
        end
    end
    if restored then World.pendingMaterials[body] = nil
    else World.pendingMaterials[body] = all end
    return restored
end

return World
