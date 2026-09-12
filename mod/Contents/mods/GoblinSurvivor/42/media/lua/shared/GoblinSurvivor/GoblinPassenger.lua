-- Native passenger geometry without VehicleEnter/Exit's IsoPlayer packets.
-- Only server roster data may attach a client-side companion to a seat.
local Motion=require("GoblinSurvivor/GoblinLocomotion")
local Hands=require("GoblinSurvivor/GoblinHands")
local Passenger={bound=setmetatable({}, {__mode="k"})}
local function call(object,key,...)
    if not object then return false end
    local ok,fn=pcall(function() return object[key] end)
    if ok and type(fn)=="function" then return pcall(fn,object,...) end
    return false
end
Passenger.call=call
function Passenger.validSeat(vehicle,seat)
    local ok,count=call(vehicle,"getMaxPassengers")
    return ok and type(count)=="number" and type(seat)=="number" and seat==math.floor(seat)
        and seat>=1 and seat<count and seat<64 -- never the driver
end
function Passenger.resolve(id,script)
    if type(id)~="number" or id~=math.floor(id) or id<0 or id>32767 or type(getVehicleById)~="function" then return nil end
    local vehicle=getVehicleById(id)
    local _,definition=call(vehicle,"getScript")
    local _,name=call(definition,"getFullName")
    if type(script)~="string" or name~=script then return nil end
    return vehicle
end
function Passenger.point(vehicle,seat,position)
    if not Passenger.validSeat(vehicle,seat) or not Vector3f then return nil end
    local vector=Vector3f.new()
    local _,definition=call(vehicle,"getPassengerPosition",seat,position or "outside")
    if not definition then return nil end
    local _,area=call(definition,"getArea")
    if type(area)=="string" and #area>0 then
        local _,script=call(vehicle,"getScript")
        local _,region=call(script,"getAreaById",area)
        local _,center=call(vehicle,"areaPositionWorld4PlayerInteract",region)
        local _,x=call(center,"getX");local _,y=call(center,"getY")
        local _,z=call(vehicle,"getZ")
        if type(x)=="number" and type(y)=="number" and type(z)=="number" then return {x=x,y=y,z=math.floor(z)} end
        return nil
    end
    local ok,result=call(vehicle,"getPassengerPositionWorldPos",definition,vector)
    if not ok or not result then return nil end
    local _,x=call(vector,"x");local _,y=call(vector,"y");local _,z=call(vector,"z")
    -- JOML exposes x()/y()/z() in the installed game.
    if type(x)~="number" or type(y)~="number" or type(z)~="number" then return nil end
    if x~=x or y~=y or z~=z or math.abs(x)>1000000 or math.abs(y)>1000000 or math.abs(z)>100 then return nil end
    return {x=x,y=y,z=math.floor(z)}
end
function Passenger.place(body,point)
    if not point then return false end
    local square=getCell():getGridSquare(math.floor(point.x),math.floor(point.y),math.floor(point.z))
    if not square then return false end
    call(body,"setX",point.x);call(body,"setY",point.y);call(body,"setZ",point.z)
    call(body,"setCurrent",square)
    return true
end
function Passenger.detach(body,point)
    local old=Passenger.bound[body]
    local _,vehicle=call(body,"getVehicle")
    vehicle=vehicle or (old and old.vehicle)
    if vehicle then
        local _,seat=call(vehicle,"getSeat",body)
        -- Never clear a replacement occupant's seat.
        if type(seat)=="number" and seat>=0 then call(vehicle,"clearPassenger",seat) end
        call(body,"setVehicle",nil)
    end
    call(body,"setCollidable",true)
    call(body,"setVariable","GoblinVehiclePhase","")
    Passenger.bound[body]=nil
    if point then Passenger.place(body,point) end
end
function Passenger.apply(body,state)
    if not state or state.vehicle_id==nil then
        if Passenger.bound[body] then Passenger.detach(body,state and state.vehicle_exit) end
        return false
    end
    local vehicle=Passenger.resolve(state.vehicle_id,state.vehicle_script)
    local seat=state.vehicle_seat
    Motion.stop(body);Hands.stow(body)
    if not vehicle or not Passenger.validSeat(vehicle,seat) then return true end -- unloaded; don't walk
    local _,occupant=call(vehicle,"getCharacter",seat)
    if occupant and occupant~=body then return true end -- never evict a player/another companion
    local _,old=call(body,"getVehicle")
    if old and (old~=vehicle or select(2,call(old,"getSeat",body))~=seat) then Passenger.detach(body) end
    local ok,entered=call(vehicle,"enterRSync",seat,body,vehicle)
    if not ok or entered~=true then return true end
    Passenger.bound[body]={vehicle=vehicle,seat=seat}
    Passenger.place(body,Passenger.point(vehicle,seat,"inside"))
    local _,direction=call(vehicle,"getForwardVector",Vector3f.new())
    if direction then
        -- Vehicle world forward uses X/Z for the ground plane.
        local _,x=call(direction,"x");local _,y=call(direction,"z")
        if type(x)=="number" and type(y)=="number" then call(body,"setForwardDirection",x,y) end
    end
    call(body,"setVariable","GoblinVehiclePhase",state.vehicle_phase or "RIDE")
    call(body,"setVariable","GoblinAction","")
    return true
end
return Passenger
