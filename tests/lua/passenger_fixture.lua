Passenger=require('GoblinSurvivor/GoblinPassenger')
Motion=require('GoblinSurvivor/GoblinLocomotion')
Movement=require('GoblinSurvivor/GoblinMovement')
Transport=require('GoblinSurvivor/GoblinTransport')
player.x=0;player.y=0
goblinServerPassengerReady=function() return true end
a.data.GoblinTask='FOLLOW'
function vector(x,y,z)
    local value={v={x or 0,y or 0,z or 0}}
    function value:x() return self.v[1] end
    function value:y() return self.v[2] end
    function value:z() return self.v[3] end
    return value
end
Vector3f={new=vector}
function actorVehicleMethods(who)
    function who:getVehicle() return self.vehicle end
    function who:setVehicle(v) self.vehicle=v end
    function who:setX(v) self.x=v end
    function who:setY(v) self.y=v end
    function who:setZ(v) self.z=v end
    function who:setCurrent(v) self.current=v end
    function who:setCollidable(v) self.collidable=v end
    function who:getVariableBoolean(k) return self.variables[k]==true end
end
actorVehicleMethods(a);actorVehicleMethods(player)
v={id=7,x=1,y=0,z=0,speed=0,seats={},locked=false,blocked=false,exitBlocked=false,entries=0,clears=0}
function v:getId() return self.id end
function v:getX() return self.x end
function v:getY() return self.y end
function v:getZ() return self.z end
function v:getScript() return {getFullName=function() return 'Base.TestCar' end} end
function v:getMaxPassengers() return 3 end
function v:isSeatInstalled(seat) return not self.missing end
function v:isSeatOccupied(seat) return self.seats[seat]~=nil or self.cargo==true end
function v:getCharacter(seat) return self.seats[seat] end
function v:getCurrentSpeedKmHour() return self.speed end
function v:isEnterBlocked(who,seat) return self.blocked end
function v:isExitBlocked(who,seat) return self.exitBlocked end
function v:getPassengerDoor(seat)
    return {getDoor=function() return {isLocked=function() return v.locked end,
        setOpen=function(_,value) v.doorOpen=value end} end}
end
function v:getPassengerPosition(seat,position) return {seat=seat,position=position} end
function v:getPassengerPositionWorldPos(def,out)
    out.v={self.x+(def.position=='inside' and 0 or 1),self.y+(def.seat-1),self.z};return out
end
function v:getForwardVector(out) out.v={0,0,1};return out end
function v:getSeat(body) for seat,who in pairs(self.seats) do if who==body then return seat end end;return -1 end
function v:enterRSync(seat,who,vehicle)
    assert(vehicle==self and seat>0)
    assert(not self.seats[seat] or self.seats[seat]==who,'overwrote occupied seat')
    self.seats[seat]=who;who.vehicle=self;who.collidable=false;self.entries=self.entries+1;return true
end
function v:clearPassenger(seat) self.seats[seat]=nil;self.clears=self.clears+1;return true end
function v:enter() error('player-only packet path called') end
function v:exit() error('player-only packet path called') end
function v:transmitPartDoor() self.doorTransmits=(self.doorTransmits or 0)+1 end
getVehicleById=function(id) return not vehicleUnloaded and id==v.id and v or nil end
function cell:getVehicles() return list({v}) end
function board()
    local p,reason=Transport.prepare(a,player,'ENTER_VEHICLE',clock);assert(p,reason)
    local point=Passenger.point(v,p.seat,'outside');a.x=point.x;a.y=point.y
    local done,ok,detail=Transport.board(a,p,clock);assert(done and ok,detail);return p
end
