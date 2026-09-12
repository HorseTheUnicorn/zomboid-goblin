local Body=require("GoblinSurvivor/GoblinBody")
local Movement=require("GoblinSurvivor/GoblinMovement")
local World=require("GoblinSurvivor/GoblinWorld")
local Passenger=require("GoblinSurvivor/GoblinPassenger")
local Transport={pending=setmetatable({}, {__mode="k"})}
local call=Passenger.call
local function stopped(vehicle)
    local ok,speed=call(vehicle,"getCurrentSpeedKmHour")
    return ok and type(speed)=="number" and speed==speed and math.abs(speed)<=0.5
end
local function say(body,text)
    local data=Body.data(body)
    if data.GoblinTransportStatus~=text then
        data.GoblinTransportStatus=text
        Body.say(body,"Comrade, "..text..".")
        print("[GoblinSurvivor] TRANSPORT owner="..Body.owner(body).." status="..text)
    end
end
local function available(body,vehicle,seat)
    if not Passenger.validSeat(vehicle,seat) then return false end
    if select(2,call(vehicle,"isSeatInstalled",seat))~=true
        or select(2,call(vehicle,"isSeatOccupied",seat))~=false then return false end
    local _,part=call(vehicle,"getPassengerDoor",seat)
    local _,door=call(part,"getDoor")
    if door and select(2,call(door,"isLocked"))~=false then return false end
    local blocked,yes=call(vehicle,"isEnterBlocked",body,seat)
    return blocked and yes==false and Passenger.point(vehicle,seat,"outside")~=nil
end
local function choose(body,vehicle)
    local _,count=call(vehicle,"getMaxPassengers")
    if type(count)~="number" then return nil end
    local selected,distance
    local p=Body.position(body)
    for seat=1,math.min(count-1,63) do
        if available(body,vehicle,seat) then
            local target=Passenger.point(vehicle,seat,"outside")
            local d=(target.x-p.x)^2+(target.y-p.y)^2
            if not distance or d<distance then selected,distance=seat,d end
        end
    end
    return selected
end
local function descriptor(vehicle)
    local _,script=call(vehicle,"getScript")
    local _,name=call(script,"getFullName")
    return select(2,call(vehicle,"getId")),name
end
function Transport.prepare(body,owner,task,now)
    if not isServer() or not owner or not Body.isGoblin(body) then return nil,"your player must be present" end
    if type(goblinServerPassengerReady)~="function" or not goblinServerPassengerReady() then
        return nil,"passenger seat protection needs the updated server-side Storm helper"
    end
    if string.lower(owner:getUsername())~=string.lower(Body.owner(body)) then return nil,"not your companion" end
    local data=Body.data(body)
    if task=="EXIT_VEHICLE" then
        if not data.GoblinRide then return nil,"I am not in a vehicle" end
        return {started_at=now},"I will get out when the vehicle stops and the exit is clear"
    end
    if data.GoblinRide then return nil,"I am already in a vehicle" end
    local _,vehicle=call(owner,"getVehicle")
    if not vehicle then
        local p=Body.position(owner);local nearest=25
        for _,candidate in ipairs(World.values(select(2,call(getCell(),"getVehicles")))) do
            local v=Body.position(candidate)
            local d=(p.x-v.x)^2+(p.y-v.y)^2
            if math.floor(p.z)==math.floor(v.z) and d<=nearest then vehicle,nearest=candidate,d end
        end
    end
    if not vehicle then return nil,"stand within five tiles of the vehicle or get in it first" end
    if not stopped(vehicle) then return nil,"stop the vehicle so I can board" end
    local seat=choose(body,vehicle)
    if not seat then return nil,"no free, installed passenger seat with an unlocked, clear entrance" end
    local id,script=descriptor(vehicle)
    return {vehicle_id=id,vehicle_script=script,seat=seat,started_at=now},"heading to a free passenger seat"
end
function Transport.clear(body)
    Transport.pending[body]=nil
end
local function state(ride)
    return {vehicle_id=ride.id,vehicle_script=ride.script,vehicle_seat=ride.seat,vehicle_phase=ride.phase}
end
function Transport.snapshot(body)
    local data=Body.data(body);local ride=data.GoblinRide
    local result=ride and state(ride) or {}
    result.vehicle_exit=data.GoblinVehicleExit
    result.vehicle_revision=data.GoblinVehicleRevision or 0
    return result
end
function Transport.board(body,payload,now)
    local vehicle=Passenger.resolve(payload.vehicle_id,payload.vehicle_script)
    if not vehicle then return true,false,"vehicle is no longer loaded" end
    if now-(payload.started_at or now)>45000 then return true,false,"could not reach the passenger door; clear a path and try again" end
    if not stopped(vehicle) then Movement.clear(body);return false,false,"waiting for the vehicle to stop" end
    if not available(body,vehicle,payload.seat) then
        payload.seat=choose(body,vehicle)
        if not payload.seat then return true,false,"passenger seats are occupied, locked, missing, or blocked" end
    end
    local goal=Passenger.point(vehicle,payload.seat,"outside")
    local p=Body.position(body)
    if math.floor(p.z)~=goal.z or (p.x-goal.x)^2+(p.y-goal.y)^2>0.64 then
        goal.radius=0.45
        local active=Movement.snapshot(body)
        if not active or not active.goal or (active.goal.x-goal.x)^2+(active.goal.y-goal.y)^2>0.04 then
            Movement.command(body,"MOVE_TO",goal)
        else Movement.update(body,now) end
        return false,true,"walking to passenger door"
    end
    -- Recheck atomically on the authoritative game thread immediately before binding.
    if not available(body,vehicle,payload.seat) then return false,false,"seat changed; checking again" end
    Movement.clear(body)
    local _,part=call(vehicle,"getPassengerDoor",payload.seat)
    local _,door=call(part,"getDoor")
    if door then call(door,"setOpen",true);call(vehicle,"transmitPartDoor",part) end
    local ok,entered=call(vehicle,"enterRSync",payload.seat,body,vehicle)
    if not ok or entered~=true then return true,false,"native passenger entry failed" end
    local data=Body.data(body)
    data.GoblinRide={id=payload.vehicle_id,script=payload.vehicle_script,seat=payload.seat,phase="ENTER",at=now}
    data.GoblinVehicleExit=nil;data.GoblinVehicleRevision=(data.GoblinVehicleRevision or 0)+1
    Passenger.apply(body,state(data.GoblinRide))
    if door then call(door,"setOpen",false);call(vehicle,"transmitPartDoor",part) end
    return true,true,"aboard; I will ride with you"
end
function Transport.exit(body,now)
    local data=Body.data(body);local ride=data.GoblinRide
    if not ride then return true,true,"already on foot" end
    local vehicle=Passenger.resolve(ride.id,ride.script)
    if not vehicle then return false,false,"waiting for the vehicle area to load" end
    if not stopped(vehicle) then return false,false,"waiting for the vehicle to stop before getting out" end
    local ok,blocked=call(vehicle,"isExitBlocked",body,ride.seat)
    local point=Passenger.point(vehicle,ride.seat,"outside")
    local square=point and World.square(point)
    if not ok or blocked or not square or select(2,call(square,"isFree",false))~=true then
        return false,false,"passenger exit is blocked; move the vehicle to a clear spot"
    end
    if ride.phase~="EXIT" then ride.phase="EXIT";ride.at=now;return false,true,"getting out" end
    if now-ride.at<700 then return false,true,"getting out" end
    local _,part=call(vehicle,"getPassengerDoor",ride.seat)
    local _,door=call(part,"getDoor")
    if door then call(door,"setOpen",true);call(vehicle,"transmitPartDoor",part) end
    Passenger.detach(body,point)
    data.GoblinRide=nil;data.GoblinVehicleExit=point
    data.GoblinVehicleRevision=(data.GoblinVehicleRevision or 0)+1
    data.GoblinBoardHold=true -- explicit exit must not immediately re-board
    Movement.clear(body)
    if door then call(door,"setOpen",false);call(vehicle,"transmitPartDoor",part) end
    return true,true,"back on foot"
end
function Transport.tick(body,owner,now)
    local data=Body.data(body);local task=data.GoblinTask
    local ride=data.GoblinRide
    local _,ownerVehicle=call(owner,"getVehicle")
    if not ownerVehicle then data.GoblinBoardHold=nil end
    if ride then
        if ride.phase=="ENTER" and now-ride.at>=700 then ride.phase="RIDE" end
        Passenger.apply(body,state(ride))
        Body.setPhysicalState(body,"IDLE","IDLE","NONE")
        -- An explicit job stays queued until a safe disembark; WAIT stays aboard.
        local exit=task=="EXIT_VEHICLE" or (task~="WAIT" and task~="ENTER_VEHICLE"
            and (task~="FOLLOW" or not owner or not ownerVehicle or ownerVehicle:getId()~=ride.id))
        if exit then
            local done,ok,detail=Transport.exit(body,now)
            if not done then say(body,detail) end
            if done then say(body,detail);return false end
        end
        return true
    end
    if task=="ENTER_VEHICLE" then
        local done,ok,detail=Transport.board(body,data.GoblinTaskPayload,now)
        if done then
            Transport.pending[body]=nil
            require("GoblinSurvivor/GoblinBrain").setTask(body,"FOLLOW",{owner=Body.owner(body)})
            say(body,detail)
        end
        return true
    end
    if task=="EXIT_VEHICLE" then
        require("GoblinSurvivor/GoblinBrain").setTask(body,"FOLLOW",{owner=Body.owner(body)})
        return true
    end
    if task=="FOLLOW" and ownerVehicle and not data.GoblinBoardHold then
        local pending=Transport.pending[body]
        if not pending or pending.vehicle_id~=ownerVehicle:getId() then
            local detail
            pending,detail=Transport.prepare(body,owner,"ENTER_VEHICLE",now)
            if not pending then Movement.clear(body);say(body,detail);return true end
            Transport.pending[body]=pending
        end
        local done,ok,detail=Transport.board(body,pending,now)
        if done then Transport.pending[body]=nil;say(body,detail) end
        return true
    end
    return false
end
return Transport
