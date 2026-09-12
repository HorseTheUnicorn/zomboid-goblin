-- Engine-facing inventory and reach checks shared by looting and construction.
local Body = require("GoblinSurvivor/GoblinBody")
local Movement = require("GoblinSurvivor/GoblinMovement")
local World = {}

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

function World.approach(body, square, now)
    if not square then return false, "target unloaded" end
    if World.reachable(body, square) then Movement.clear(body); return true, "arrived" end
    local point, nearest, best = Body.position(body), nil, math.huge
    for _, offset in ipairs({{0,0},{-1,0},{1,0},{0,-1},{0,1}}) do
        local sq = getCell():getGridSquare(square:getX()+offset[1], square:getY()+offset[2], square:getZ())
        local freeOK, free = call(sq, "isFree", false)
        local clearOK, blocked = call(sq, "isBlockedTo", square)
        if freeOK and free and (sq == square or (clearOK and not blocked)) then
            local p = World.point(sq)
            local d = (p.x-point.x)^2 + (p.y-point.y)^2
            if d < best then nearest, best = p, d end
        end
    end
    if not nearest then return false, "no accessible work square" end
    nearest.radius = 0.45
    local active = Movement.snapshot(body)
    local goal = active and active.goal
    if not goal or goal.x ~= nearest.x or goal.y ~= nearest.y or goal.z ~= nearest.z then
        Movement.command(body, "MOVE_TO", nearest)
    else Movement.update(body, now) end
    return false, "walking to supplies/work"
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
