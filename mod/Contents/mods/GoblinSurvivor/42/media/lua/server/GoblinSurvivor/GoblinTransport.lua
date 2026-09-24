local Body=require("GoblinSurvivor/GoblinBody")
local Movement=require("GoblinSurvivor/GoblinMovement")
local World=require("GoblinSurvivor/GoblinWorld")
local Passenger=require("GoblinSurvivor/GoblinPassenger")
local Policy=require("GoblinSurvivor/GoblinAccessPolicy")
local Transport={pending=setmetatable({}, {__mode="k"}),boardRetry=setmetatable({}, {__mode="k"}),engineWatch=setmetatable({}, {__mode="k"})}
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
local function engineSnapshot(vehicle)
    local _,engine=call(vehicle,"getPartById","Engine")
    local _,condition=call(engine,"getCondition")
    local _,gas=call(vehicle,"getGasRemaining")
    local _,running=call(vehicle,"isEngineRunning")
    local _,native=call(vehicle,"getVehicleEngine")
    local _,state=call(native,"getState")
    local _,reason=call(native,"getStateChangeReason")
    return running==true,condition,gas,tostring(state),tostring(reason)
end
local function watchEngine(body,vehicle,now)
    local watch=Transport.engineWatch[body]
    if not watch then return end
    if now>watch.until_at or not vehicle or select(2,call(vehicle,"getId"))~=watch.id then
        Transport.engineWatch[body]=nil
        return
    end
    local running,condition,gas,state,reason=engineSnapshot(vehicle)
    if running~=watch.running then
        print("[GoblinSurvivor] TRANSPORT_ENGINE_TRANSITION owner="..Body.owner(body)
            .." vehicle_id="..tostring(watch.id).." running="..tostring(running)
            .." engine_condition="..tostring(condition).." gas="..tostring(gas)
            .." native_state="..state.." reason="..reason)
        watch.running=running
    end
end
local function doorAccessible(body,vehicle,part,door)
    if not door then return true end
    local inspected,locked=call(door,"isLocked")
    if not inspected then return false,"passenger door lock state unavailable" end
    if locked~=true then return true end
    -- Exact installed BaseVehicle.canOpenDoor/canUnlockDoor accept an
    -- IsoGameCharacter and inspect its inventory for the vehicle key without
    -- casting to IsoPlayer. Do not clear a lock merely because Goblin owns a
    -- generic toolkit.
    local checked,allowed=call(vehicle,"canOpenDoor",part,body)
    if not checked or allowed~=true then return false,"passenger door locked without Goblin's matching key" end
    return true
end
local function available(body,vehicle,seat)
    if not Passenger.validSeat(vehicle,seat) then return false,"invalid passenger seat" end
    if select(2,call(vehicle,"isSeatInstalled",seat))~=true then return false,"passenger seat missing" end
    if select(2,call(vehicle,"isSeatOccupied",seat))~=false then return false,"passenger seat occupied" end
    local _,part=call(vehicle,"getPassengerDoor",seat)
    local _,door=call(part,"getDoor")
    local accessible,doorReason=doorAccessible(body,vehicle,part,door)
    if not accessible then return false,doorReason end
    local blocked,yes=call(vehicle,"isEnterBlocked",body,seat)
    if not blocked then return false,"passenger approach check unavailable" end
    if yes~=false then return false,"passenger approach physically blocked" end
    if not Passenger.point(vehicle,seat,"outside") then return false,"outside passenger position unavailable" end
    return true
end
local function unlockWithNativeKey(body,vehicle,seat)
    local _,part=call(vehicle,"getPassengerDoor",seat)
    local _,door=call(part,"getDoor")
    if not door then return true,part,door end
    local inspected,locked=call(door,"isLocked")
    if not inspected then return false,part,door end
    if locked~=true then return true,part,door end
    local checked,allowed=call(vehicle,"canUnlockDoor",part,body)
    if not checked or allowed~=true then return false,part,door end
    local invoked=call(vehicle,"toggleLockedDoor",part,body,false)
    local verified,newLocked=call(door,"isLocked")
    if not invoked or not verified or newLocked==true then return false,part,door end
    call(vehicle,"transmitPartDoor",part)
    return true,part,door
end
local function choose(body,vehicle)
    local _,count=call(vehicle,"getMaxPassengers")
    if type(count)~="number" then return nil,"passenger seat count unavailable" end
    local selected,distance,failures
    failures={}
    local p=Body.position(body)
    for seat=1,math.min(count-1,63) do
        local eligible,reason=available(body,vehicle,seat)
        if eligible then
            local target=Passenger.point(vehicle,seat,"outside")
            local d=(target.x-p.x)^2+(target.y-p.y)^2
            if not distance or d<distance then selected,distance=seat,d end
        else
            failures[#failures+1]="seat "..seat..": "..(reason or "unavailable")
        end
    end
    return selected,table.concat(failures,"; ")
end
local function descriptor(vehicle)
    local _,script=call(vehicle,"getScript")
    local _,name=call(script,"getFullName")
    return select(2,call(vehicle,"getId")),name
end
local function lockedDoor(body,vehicle)
    local _,count=call(vehicle,"getMaxPassengers")
    if type(count)~="number" then return nil end
    local selected,point,distance
    local here=Body.position(body)
    for seat=0,math.min(count-1,63) do
        local _,part=call(vehicle,"getPassengerDoor",seat)
        local _,door=call(part,"getDoor")
        if select(2,call(door,"isLocked"))==true then
            local outside=Passenger.doorPoint(vehicle,seat,"outside")
            if outside and math.floor(here.z)==outside.z then
                local d=(outside.x-here.x)^2+(outside.y-here.y)^2
                if not distance or d<distance then selected,point,distance=seat,outside,d end
            end
        end
    end
    return selected,point
end
local function foreignOccupant(vehicle,owner,body)
    local _,count=call(vehicle,"getMaxPassengers")
    if type(count)~="number" then return true end
    for seat=0,math.min(count-1,63) do
        local checked,occupant=call(vehicle,"getCharacter",seat)
        if not checked or (occupant and occupant~=owner and occupant~=body) then return true end
    end
    return false
end
local function locksClear(vehicle)
    local _,count=call(vehicle,"getMaxPassengers")
    if type(count)~="number" then return false end
    for seat=0,math.min(count-1,63) do
        local _,part=call(vehicle,"getPassengerDoor",seat)
        local _,door=call(part,"getDoor")
        if door and select(2,call(door,"isLocked"))~=false then return false end
    end
    local checked,trunkLocked=call(vehicle,"isTrunkLocked")
    return checked and trunkLocked~=true
end
function Transport.prepare(body,owner,task,now)
    if not isServer() or not owner or not Body.isGoblin(body) then return nil,"your player must be present" end
    if type(goblinServerPassengerReady)~="function" or not goblinServerPassengerReady() then
        return nil,"passenger seat protection needs the updated server-side Storm helper"
    end
    if string.lower(owner:getUsername())~=string.lower(Body.owner(body)) then return nil,"not your companion" end
    local data=Body.data(body)
    if task=="UNLOCK_VEHICLE" then
        local _,vehicle=call(owner,"getVehicle")
        local seat,point
        if vehicle then seat,point=lockedDoor(body,vehicle) end
        if not vehicle then
            local ownerPos=Body.position(owner);local nearest=25
            for _,candidate in ipairs(World.values(select(2,call(getCell(),"getVehicles")))) do
                local candidatePos=Body.position(candidate)
                local d=(ownerPos.x-candidatePos.x)^2+(ownerPos.y-candidatePos.y)^2
                if math.floor(ownerPos.z)==math.floor(candidatePos.z) and d<=nearest then
                    local candidateSeat,candidatePoint=lockedDoor(body,candidate)
                    if candidateSeat then vehicle,seat,point,nearest=candidate,candidateSeat,candidatePoint,d end
                end
            end
        end
        if not vehicle then return nil,"no locked vehicle within five tiles of you" end
        if not seat then return nil,"vehicle has no reachable locked entry door" end
        if not stopped(vehicle) then return nil,"stop the vehicle before unlocking it" end
        if foreignOccupant(vehicle,owner,body) then
            return nil,"another player or companion is inside that vehicle"
        end
        local allowed,_,reason=Policy.access(body,vehicle)
        if not allowed then return nil,reason end
        local id,script=descriptor(vehicle)
        return {vehicle_id=id,vehicle_script=script,seat=seat,point=point,started_at=now},
            "going to unlock the nearby vehicle"
    end
    if task=="EXIT_VEHICLE" then
        if not data.GoblinRide then return nil,"I am not in a vehicle" end
        return {started_at=now},"I will get out when the vehicle stops and the exit is clear"
    end
    if task=="START_VEHICLE" then
        local ride=data.GoblinRide
        if not ride then return nil,"I must be aboard your vehicle to start it" end
        local vehicle=Passenger.resolve(ride.id,ride.script)
        local _,ownerVehicle=call(owner,"getVehicle")
        local _,driver=call(vehicle,"getDriver")
        local _,bodyVehicle=call(body,"getVehicle")
        local _,bodySeat=call(vehicle,"getSeat",body)
        if not vehicle or ownerVehicle~=vehicle or driver~=owner then
            return nil,"you must be driving the same vehicle I am riding in"
        end
        if bodyVehicle~=vehicle or type(bodySeat)~="number" or bodySeat~=ride.seat or bodySeat<1 then
            return nil,"I must be seated as your passenger before starting it"
        end
        if not stopped(vehicle) then return nil,"stop the vehicle before keyless starting" end
        if select(2,call(vehicle,"isEngineWorking"))~=true then
            return nil,"the engine is not working"
        end
        return {vehicle_id=ride.id,vehicle_script=ride.script,started_at=now},
            "using the keyless ignition while you drive"
    end
    if data.GoblinRide then return nil,"I am already in a vehicle" end
    local _,vehicle=call(owner,"getVehicle")
    local seat
    if not vehicle then
        local p=Body.position(owner);local nearest=25;local nearby=false
        for _,candidate in ipairs(World.values(select(2,call(getCell(),"getVehicles")))) do
            local v=Body.position(candidate)
            local d=(p.x-v.x)^2+(p.y-v.y)^2
            if math.floor(p.z)==math.floor(v.z) and d<=25 then
                nearby=true
                local candidateSeat=stopped(candidate) and choose(body,candidate)
                if candidateSeat and d<=nearest then vehicle,seat,nearest=candidate,candidateSeat,d end
            end
        end
        if not vehicle and nearby then
            return nil,"nearby vehicles have no stopped, free, unlocked passenger seat"
        end
    end
    if not vehicle then return nil,"stand within five tiles of the vehicle or get in it first" end
    if not stopped(vehicle) then return nil,"stop the vehicle so I can board" end
    local seatReason
    if not seat then seat,seatReason=choose(body,vehicle) end
    if not seat then return nil,"no usable passenger seat ("..seatReason..")" end
    local id,script=descriptor(vehicle)
    return {vehicle_id=id,vehicle_script=script,seat=seat,started_at=now},"heading to a free passenger seat"
end
function Transport.clear(body)
    Transport.pending[body]=nil
end
local function deferBoard(body,vehicleId,now)
    Transport.boardRetry[body]={vehicle_id=vehicleId,until_at=now+15000}
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
    local unlocked,part,door=unlockWithNativeKey(body,vehicle,payload.seat)
    if not unlocked then return true,false,"passenger door is locked and Goblin has no matching key" end
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
    -- The installed BaseVehicle exitRSync accepts IsoGameCharacter and returns
    -- false when its seat could not be cleared. The player-only VehicleExitPacket
    -- is never sent for our managed IsoZombie.
    local invoked,exited=call(vehicle,"exitRSync",body)
    local _,seat=call(vehicle,"getSeat",body)
    local _,attached=call(body,"getVehicle")
    if door then call(door,"setOpen",false);call(vehicle,"transmitPartDoor",part) end
    if not invoked or exited~=true or seat~=-1 or attached then
        return false,false,"native passenger exit failed; still aboard"
    end
    Passenger.detach(body,point)
    data.GoblinRide=nil;data.GoblinVehicleExit=point
    data.GoblinVehicleRevision=(data.GoblinVehicleRevision or 0)+1
    data.GoblinBoardHold=true -- explicit exit must not immediately re-board
    Movement.clear(body)
    return true,true,"back on foot"
end
function Transport.start(body,owner,payload,now)
    if not isServer() or not owner or not Body.isGoblin(body) then
        return true,false,"keyless start requires your Goblin and an online driver"
    end
    local ride=Body.data(body).GoblinRide
    local vehicle=ride and Passenger.resolve(ride.id,ride.script)
    local _,ownerVehicle=call(owner,"getVehicle")
    local _,driver=call(vehicle,"getDriver")
    local _,bodyVehicle=call(body,"getVehicle")
    local _,bodySeat=call(vehicle,"getSeat",body)
    if not vehicle or vehicle~=ownerVehicle or vehicle~=bodyVehicle or driver~=owner
        or type(bodySeat)~="number" or bodySeat~=ride.seat or bodySeat<1 then
        return true,false,"driver or Goblin changed vehicles; ignition canceled"
    end
    if not stopped(vehicle) then return true,false,"vehicle moved; ignition canceled" end
    if select(2,call(vehicle,"isEngineRunning"))==true then
        return true,true,"engine is running"
    end
    if select(2,call(vehicle,"isEngineWorking"))~=true then
        return true,false,"the engine is not working"
    end
    if select(2,call(vehicle,"hasLiveBattery"))~=true then
        return true,false,"the battery has no charge"
    end
    payload=type(payload)=="table" and payload or {}
    if now-(payload.started_at or now)>45000 then
        return true,false,"engine did not start after keyless ignition attempts"
    end
    if not payload.last_attempt or now-payload.last_attempt>=5000 then
        local _,starting=call(vehicle,"isStarting")
        if starting~=true then
            -- Installed BaseVehicle.tryStartEngine(true) bypasses the key check,
            -- but retains normal engine/battery checks and native replication.
            -- It returns void, so success is the observed running state only.
            if not call(vehicle,"tryStartEngine",true) then
                return true,false,"native keyless ignition is unavailable"
            end
            payload.last_attempt=now
            print("[GoblinSurvivor] TRANSPORT_KEYLESS_ATTEMPT owner="..Body.owner(body)
                .." vehicle_id="..tostring(ride.id))
        end
    end
    return false,true,"turning the keyless ignition"
end
function Transport.unlock(body,owner,payload,now)
    if not isServer() or not owner or not Body.isGoblin(body) then
        return true,false,"vehicle unlock requires your online Goblin"
    end
    payload=type(payload)=="table" and payload or {}
    local vehicle=Passenger.resolve(payload.vehicle_id,payload.vehicle_script)
    if not vehicle then return true,false,"vehicle is no longer loaded" end
    local ownerPos=Body.position(owner);local vehiclePos=Body.position(vehicle)
    local _,ownerVehicle=call(owner,"getVehicle")
    if ownerVehicle~=vehicle and (math.floor(ownerPos.z)~=math.floor(vehiclePos.z)
        or (ownerPos.x-vehiclePos.x)^2+(ownerPos.y-vehiclePos.y)^2>25) then
        return true,false,"you moved more than five tiles from the vehicle"
    end
    if not stopped(vehicle) then return true,false,"vehicle moved; unlock canceled" end
    if foreignOccupant(vehicle,owner,body) then
        return true,false,"another player or companion entered that vehicle"
    end
    if now-(payload.started_at or now)>45000 then
        return true,false,"could not reach the vehicle door in time"
    end
    local allowed,_,reason=Policy.access(body,vehicle)
    if not allowed then return true,false,reason end
    local _,part=call(vehicle,"getPassengerDoor",payload.seat)
    local _,door=call(part,"getDoor")
    if not door then return true,false,"vehicle door changed" end
    if locksClear(vehicle) then return true,true,"vehicle is already unlocked" end
    local point=Passenger.doorPoint(vehicle,payload.seat,"outside")
    if not point then return true,false,"vehicle door position changed" end
    local _,bodyVehicle=call(body,"getVehicle")
    if bodyVehicle~=vehicle then
        local here=Body.position(body)
        if math.floor(here.z)~=point.z or (here.x-point.x)^2+(here.y-point.y)^2>0.64 then
            point.radius=0.45
            local active=Movement.snapshot(body)
            if not active or not active.goal or (active.goal.x-point.x)^2+(active.goal.y-point.y)^2>0.04 then
                Movement.command(body,"MOVE_TO",point)
            else Movement.update(body,now) end
            return false,true,"walking to the locked vehicle door"
        end
    end
    Movement.clear(body)
    local changed=call(vehicle,"setLocked",false)
    if not changed or not locksClear(vehicle) then
        return true,false,"native vehicle unlock did not clear all door and trunk locks"
    end
    print("[GoblinSurvivor] TRANSPORT_UNLOCK_RESULT owner="..Body.owner(body)
        .." vehicle_id="..tostring(payload.vehicle_id).." seat="..tostring(payload.seat)
        .." unlocked=true")
    return true,true,"vehicle is unlocked"
end
function Transport.tick(body,owner,now)
    local data=Body.data(body);local task=data.GoblinTask
    local ride=data.GoblinRide
    local _,ownerVehicle=call(owner,"getVehicle")
    if not ownerVehicle then
        data.GoblinBoardHold=nil
        Transport.boardRetry[body]=nil
    end
    if ride then
        watchEngine(body,Passenger.resolve(ride.id,ride.script),now)
        if ride.phase=="ENTER" and now-ride.at>=700 then ride.phase="RIDE" end
        Passenger.apply(body,state(ride))
        Body.setPhysicalState(body,"IDLE","IDLE","NONE")
        if task=="START_VEHICLE" or task=="UNLOCK_VEHICLE" then
            local done,ok,detail
            if task=="START_VEHICLE" then
                done,ok,detail=Transport.start(body,owner,data.GoblinTaskPayload,now)
            else done,ok,detail=Transport.unlock(body,owner,data.GoblinTaskPayload,now) end
            if done then
                if task=="START_VEHICLE" and ok then
                    local vehicle=Passenger.resolve(ride.id,ride.script)
                    local running,condition,gas,state,reason=engineSnapshot(vehicle)
                    print("[GoblinSurvivor] TRANSPORT_ENGINE_STARTED owner="..Body.owner(body)
                        .." vehicle_id="..tostring(ride.id).." running="..tostring(running)
                        .." engine_condition="..tostring(condition).." gas="..tostring(gas)
                        .." native_state="..state.." reason="..reason)
                    Transport.engineWatch[body]={id=ride.id,running=running,until_at=now+90000}
                end
                require("GoblinSurvivor/GoblinBrain").setTask(body,"FOLLOW",{owner=Body.owner(body)})
                print("[GoblinSurvivor] TRANSPORT_ACTION_RESULT task="..task
                    .." owner="..Body.owner(body).." success="..tostring(ok).." detail="..detail)
            end
            say(body,detail)
            return true
        end
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
    Transport.engineWatch[body]=nil
    if task=="ENTER_VEHICLE" then
        local done,ok,detail=Transport.board(body,data.GoblinTaskPayload,now)
        if done then
            Transport.pending[body]=nil
            if not ok then deferBoard(body,data.GoblinTaskPayload.vehicle_id,now) end
            require("GoblinSurvivor/GoblinBrain").setTask(body,"FOLLOW",{owner=Body.owner(body)})
            say(body,detail)
        end
        return true
    end
    if task=="EXIT_VEHICLE" then
        require("GoblinSurvivor/GoblinBrain").setTask(body,"FOLLOW",{owner=Body.owner(body)})
        return true
    end
    if task=="START_VEHICLE" then
        require("GoblinSurvivor/GoblinBrain").setTask(body,"FOLLOW",{owner=Body.owner(body)})
        say(body,"I am no longer aboard; ignition canceled")
        return true
    end
    if task=="UNLOCK_VEHICLE" then
        local done,ok,detail=Transport.unlock(body,owner,data.GoblinTaskPayload,now)
        if done then
            require("GoblinSurvivor/GoblinBrain").setTask(body,"FOLLOW",{owner=Body.owner(body)})
            print("[GoblinSurvivor] TRANSPORT_ACTION_RESULT task="..task
                .." owner="..Body.owner(body).." success="..tostring(ok).." detail="..detail)
        end
        if done or detail~="walking to the locked vehicle door" then say(body,detail) end
        return true
    end
    if task=="FOLLOW" and ownerVehicle and not data.GoblinBoardHold then
        local pending=Transport.pending[body]
        if not stopped(ownerVehicle) then
            if pending then Transport.pending[body]=nil;Movement.clear(body) end
            return false -- moving car: retain ordinary follow/rejoin rather than freeze
        end
        local retry=Transport.boardRetry[body]
        if retry and retry.vehicle_id==ownerVehicle:getId() and now<retry.until_at then
            return false
        end
        Transport.boardRetry[body]=nil
        if not pending or pending.vehicle_id~=ownerVehicle:getId() then
            local detail
            pending,detail=Transport.prepare(body,owner,"ENTER_VEHICLE",now)
            if not pending then
                deferBoard(body,ownerVehicle:getId(),now)
                say(body,detail)
                return false
            end
            Transport.pending[body]=pending
        end
        local done,ok,detail=Transport.board(body,pending,now)
        if done then
            Transport.pending[body]=nil
            if not ok then
                deferBoard(body,pending.vehicle_id,now)
                Movement.clear(body)
            end
            say(body,detail)
            if not ok then return false end
        end
        return true
    end
    return false
end
return Transport
