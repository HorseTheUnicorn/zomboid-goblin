-- Engine-facing inventory and reach checks shared by looting and construction.
local Body = require("GoblinSurvivor/GoblinBody")
local Movement = require("GoblinSurvivor/GoblinMovement")
local Motion = require("GoblinSurvivor/GoblinLocomotion")
local World = { approaches = setmetatable({}, { __mode = "k" }) }

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
    for i = 0, (tonumber(n) or 0) - 1 do
        local _, value = call(list, "get", i)
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

function World.reachable(body, square)
    local here = World.square(Body.position(body))
    if not here or not square or here:getZ() ~= square:getZ() then return false end
    if math.abs(here:getX()-square:getX()) > 1 or math.abs(here:getY()-square:getY()) > 1 then return false end
    if here == square then return true end
    local ok, blocked = call(here, "isBlockedTo", square)
    return ok and blocked == false
end

local function squareOccupied(square, body)
    local objects = World.values(select(2, call(square, "getMovingObjects")))
    for _, object in ipairs(objects) do if object ~= body then return true end end
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
                local _, fire = call(square, "haveFire")
                local clear = ring > 1 or square == target
                if ring == 1 and square ~= target then
                    local clearOK, blocked = call(square, "isBlockedTo", target)
                    clear = clearOK and blocked == false
                end
                if square and freeOK and free == true and fire ~= true and clear
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
    local _,fire=call(square,"haveFire")
    if not freeOK or free~=true or fire==true or squareOccupied(square,body)
        or Motion.isBlacklisted(body,candidate.key,now,"approach") then return false end
    if candidate.ring==1 and square~=target then
        local clearOK,blocked=call(square,"isBlockedTo",target)
        if not clearOK or blocked~=false then return false end
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
        state.chosen,state.staging=nil,nil
    end
    -- Keep one accepted approach while it remains valid. Re-scoring from the
    -- actor's new position every tick makes the best radius-2 point orbit the
    -- target and causes a client-owned actor to chase a moving destination.
    local candidate, reason = state.chosen, nil
    if not candidate then
        candidate,reason=World.approachCandidate(body,square,now,not state.staged)
        state.chosen=candidate
    end
    if not candidate then return false, reason end
    if candidate.ring > 1 then state.staging = candidate.point else state.staging = nil; state.staged = false end
    local nearest = candidate.point
    nearest.radius = 0.45
    nearest.approach_type = candidate.ring > 1 and "work_staging" or "work_approach"
    nearest.approach_ring = candidate.ring
    nearest.goal_key = candidate.key
    nearest.blacklist_kind = "approach"
    local active = Movement.snapshot(body)
    local goal = active and active.goal
    if not goal or goal.x ~= nearest.x or goal.y ~= nearest.y or goal.z ~= nearest.z then
        Movement.command(body, "MOVE_TO", nearest)
    else
        local ok, detail = Movement.update(body, now)
        if not ok and detail and string.find(detail, "progress") then
            Motion.blacklist(body, candidate.key, detail, now, "approach")
            state.chosen,state.staging=nil,nil
        end
    end
    return false, candidate.reason == "radius-2 staging approach"
        and "walking to alternate work approach" or "walking to supplies/work"
end

function World.sources(center, radius, accept)
    local found = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = World.square({x=center.x+dx,y=center.y+dy,z=center.z})
            if square then
                for _, object in ipairs(World.values(select(2, call(square, "getWorldObjects")))) do
                    local _, item = call(object, "getItem")
                    if item and accept(item) then found[#found+1]={square=square,world=object,item=item} end
                end
                for _, object in ipairs(World.values(select(2, call(square, "getObjects")))) do
                    local _, locked = call(object, "isLocked")
                    local _, container = call(object, "getContainer")
                    if container and not locked then
                        for _, item in ipairs(World.items(container)) do
                            if accept(item) then found[#found+1]={square=square,container=container,item=item} end
                        end
                    end
                end
            end
        end
    end
    table.sort(found, function(a,b)
        local pa,pb=World.point(a.square),World.point(b.square)
        return (pa.x-center.x)^2+(pa.y-center.y)^2 < (pb.x-center.x)^2+(pb.y-center.y)^2
    end)
    return found
end

function World.has(container, item)
    for _, candidate in ipairs(World.items(container)) do if candidate == item then return true end end
    return false
end

function World.take(body, source)
    if not World.reachable(body, source.square) then return false end
    local inv, item = World.inventory(body), source.item
    local roomOK, room = call(inv, "hasRoomFor", body, item)
    if not roomOK or room ~= true then return false end
    if source.container then
        if not World.has(source.container, item) then return false end
        source.container:Remove(item)
        if World.has(source.container,item) then return false end
    else
        local _, current = call(source.world, "getSquare")
        if current ~= source.square then return false end
    end
    local added, value = call(inv, "AddItem", item)
    if not added or value == nil or value == false then
        if source.container then source.container:AddItem(item) end
        return false
    end
    if source.container then
        if type(sendRemoveItemFromContainer) == "function" then sendRemoveItemFromContainer(source.container,item) end
    else
        source.square:transmitRemoveItemFromSquare(source.world)
        source.world:removeFromWorld()
        source.world:removeFromSquare()
        item:setWorldItem(nil)
    end
    return true
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
    local inv = World.inventory(body)
    for _, item in ipairs(selected) do if not World.has(inv,item) then return false end end
    local removed = {}
    for _, item in ipairs(selected) do
        inv:Remove(item)
        if World.has(inv,item) then World.refund(body,removed); return false end
        removed[#removed+1]=item
    end
    return true
end
function World.refund(body, selected)
    local inv = World.inventory(body)
    for _, item in ipairs(selected) do if not World.has(inv,item) then inv:AddItem(item) end end
end

return World
