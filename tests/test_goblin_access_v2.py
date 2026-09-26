from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class AccessV2Tests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / scope / "?.lua").as_posix() for scope in ("shared", "server", "client")
        )
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ("goblin_fixture.lua", "work_fixture.lua"):
            self.lua.execute((ROOT / "tests/lua" / filename).read_text())
        self.lua.execute('''
            Policy=require('GoblinSurvivor/GoblinAccessPolicy')
            Access=require('GoblinSurvivor/GoblinAccess')
            GainAccess=require('GoblinSurvivor/GoblinGainAccess')
            Jobs=require('GoblinSurvivor/GoblinJobs')
            target={square=cell:getGridSquare(1,0,0)}
            function target:getSquare() return self.square end
            function installBuilding(square)
                local building={};local room={x=square.x,y=square.y,x2=square.x,y2=square.y,
                    z=square.z,building=building}
                function room:getX() return self.x end;function room:getY() return self.y end
                function room:getX2() return self.x2 end;function room:getY2() return self.y2 end
                function room:getZ() return self.z end;function room:getBuilding() return self.building end
                function building:getRooms() return list({room}) end
                function square:getRoom() return room end
                return building,room
            end
            function nativeHop(from,to)
                IsoDirections={E='east',W='west',N='north',S='south'}
                function from:isPlayerAbleToHopWallTo(direction,other)
                    return other==to
                end
            end
        ''')

    def test_gain_access_is_registered_and_opens_real_selected_door(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(there)
            local door={opened=false,locked=false,square=here,calls=0}
            function door:getSquare() return self.square end
            function door:isOpen() return self.opened end;door.IsOpen=door.isOpen
            function door:isLocked() return self.locked end
            function door:isLockedByKey() return false end
            function door:isLockedByPadlock() return false end
            function door:getLockedByCode() return 0 end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function door:ToggleDoor(who) assert(who==a);self.opened=true;self.calls=self.calls+1 end
            function here:getDoorTo(other) if other==there then return door end end
            local descriptor=Jobs.registry();local found=false
            for _,value in ipairs(descriptor) do
                if value.name=='GAIN_ACCESS' then found=value.destructive and value.owner_required end
            end
            assert(found)
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(payload and payload.access_method=='DOOR',detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and result.success and result.code=='MOVING_TO_TARGET')
            assert(door.opened and door.calls==1)
            a.x=1.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and result.success and result.code=='COMPLETE')
        ''')

    def test_building_access_does_not_send_inside_actor_back_outside(self):
        self.lua.execute('''
            player.x=0;player.y=0;a.x=0.5;a.y=0.5
            local inside=cell:getGridSquare(0,0,0);local outside=cell:getGridSquare(1,0,0)
            installBuilding(inside)
            local door={}
            function door:isOpen() return true end;door.IsOpen=door.isOpen
            function inside:getDoorTo(other) if other==outside then return door end end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(payload,detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(result.done and result.success and result.code=='COMPLETE',
                'an actor already inside must not be ordered outside')
            assert(not a.destination, 'already accessible building must not start outward movement')
        ''')

    def test_real_brain_boundary_persists_gain_access_task(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(here)
            local door={opened=false,locked=false,square=here}
            function door:getSquare() return self.square end
            function door:isOpen() return self.opened end;door.IsOpen=door.isOpen
            function door:isLocked() return self.locked end
            function door:isLockedByKey() return false end
            function door:isLockedByPadlock() return false end
            function door:getLockedByCode() return 0 end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function here:getDoorTo(other) if other==there then return door end end
            local Constants=require('GoblinSurvivor/Constants')
            assert(Constants.TASK.GAIN_ACCESS=='GAIN_ACCESS')
            assert(Constants.ALLOWED_TASKS.GAIN_ACCESS==true)
            local Brain=require('GoblinSurvivor/GoblinBrain')
            local ok,detail=Brain.setTask(a,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(ok,detail)
            assert(a.data.GoblinTask=='GAIN_ACCESS')
            assert(a.data.GoblinTaskPayload.access_method=='DOOR')
        ''')

    def test_scoped_access_persists_and_requires_the_interior_side(self):
        self.lua.execute('''
            player.x=0;player.y=0;a.x=-2.5;a.y=0.5
            local outside=cell:getGridSquare(0,0,0);local inside=cell:getGridSquare(1,0,0)
            local building,room=installBuilding(inside)
            local door={}
            function door:isOpen() return true end;door.IsOpen=door.isOpen
            function outside:getDoorTo(other) if other==inside then return door end end
            local edge={x=0,y=0,z=0,dx=1,dy=0}
            assert(Access.destinationSide(edge,{target_room=room})==2)
            assert(Access.destinationSide({x=1,y=0,z=0,dx=-1,dy=0},{target_room=room})==1)
            assert(Access.destinationSide(edge,{target_room={}})==nil)
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='ROOM'}})
            assert(payload and payload.destination_side==2,detail)
            assert(require('GoblinSurvivor/GoblinCapabilities').serializable(payload))
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and a.destination.x==1.5)
            a.x=0.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(not result.done and a.destination.x==1.5)
            a.x=1.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+200)
            assert(result.done and result.success and result.code=='COMPLETE')
        ''')

    def test_alternate_access_route_preserves_its_own_destination_side(self):
        self.lua.execute('''
            a.x=5.5;a.y=5.5
            for _,y in ipairs({0,2}) do
                local here=cell:getGridSquare(0,y,0);local there=cell:getGridSquare(1,y,0)
                local door={}
                function door:isOpen() return true end;door.IsOpen=door.isOpen
                function here:getDoorTo(other) if other==there then return door end end
            end
            local payload={target_kind='BUILDING',access_method='DOOR',destination_side=1,cross_from=2,
                edge={x=0,y=0,z=0,dx=1,dy=0},alternates={
                    {access_method='DOOR',destination_side=2,edge={x=0,y=2,z=0,dx=1,dy=0}}
                }}
            local runtime={access_opened=true,cross_started_at=clock-31000}
            local done,success,detail,code=GainAccess.update(a,payload,runtime,clock)
            assert(not done and success and code=='MOVING_TO_TARGET',detail)
            assert(payload.destination_side==2 and payload.edge.y==2 and payload.cross_from==nil)
            assert(runtime.access_opened==nil and runtime.cross_approach_started_at==nil)
            runtime.access_opened=true;payload.destination_side=3
            done,success,detail,code=GainAccess.update(a,payload,runtime,clock+100)
            assert(done and not success and code=='TARGET_CHANGED',detail)
            payload.destination_side=2;payload.cross_from=3
            done,success,detail,code=GainAccess.update(a,payload,runtime,clock+200)
            assert(done and not success and code=='TARGET_CHANGED',detail)
        ''')

    def test_already_open_route_approaches_before_observed_crossing(self):
        self.lua.execute('''
            player.x=0;player.y=0;a.x=4.5;a.y=0.5
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(here)
            local door={opened=true,locked=false,square=here}
            function door:getSquare() return self.square end
            function door:isOpen() return self.opened end;door.IsOpen=door.isOpen
            function door:isLocked() return false end
            function door:isLockedByKey() return false end
            function door:isLockedByPadlock() return false end
            function door:getLockedByCode() return 0 end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function here:getDoorTo(other) if other==there then return door end end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(payload and payload.access_method=='DOOR',detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and result.success and result.code=='MOVING_TO_TARGET')
            assert(a.destination and a.destination.x==0.5 and a.destination.y==0.5)
            a.x=1.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(not result.done and result.success and result.code=='MOVING_TO_TARGET')
            a.x=0.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+200)
            assert(result.done and result.success and result.code=='COMPLETE')
        ''')

    def test_yard_crossing_survives_runtime_loss_without_crossing_back(self):
        self.lua.execute('''
            player.x=0;player.y=0;a.x=0.5;a.y=0.5
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local door={toggles=0}
            function door:isOpen() return true end;door.IsOpen=door.isOpen
            function door:ToggleDoor() self.toggles=self.toggles+1 end
            function here:getDoorTo(other) if other==there then return door end end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload,detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and a.destination.x==1.5)
            assert(payload.cross_from==1)
            assert(require('GoblinSurvivor/GoblinCapabilities').serializable(payload))
            Jobs.clear(a)
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+50)
            assert(not result.done and a.destination.x==1.5)
            -- Engine movement completed before the next job tick. Restore the
            -- primitive job with no weak-table runtime, as after reattachment.
            a.x=1.5
            Jobs.clear(a)
            a.destination=nil
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and result.success and result.code=='COMPLETE',
                'restored access must recognize the completed crossing')
            assert(not a.destination and door.toggles==0)
        ''')

    def test_open_access_rechecks_safehouse_after_approach_starts(self):
        self.lua.execute('''
            player.x=0;player.y=0;a.x=-2.5;a.y=0.5
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(there)
            local door={}
            function door:getSquare() return here end
            function door:isOpen() return true end;door.IsOpen=door.isOpen
            function here:getDoorTo(other) if other==there then return door end end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(payload,detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done)
            SafeHouse={getSafeHouse=function() return {playerAllowed=function() return false end} end}
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and not result.success and result.code=='PERMISSION_DENIED',
                'an open route must not retain revoked access')
        ''')

    def test_already_smashed_window_still_checks_breach_policy(self):
        self.lua.execute('''
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local window={}
            function window:getSquare() return here end
            function window:isSmashed() return true end
            function here:getWindowTo(other) if other==there then return window end end
            SafeHouse={getSafeHouse=function() return {playerAllowed=function() return false end} end}
            local done,success,detail,code=Access.performBreachWindow(a,
                {edge={x=0,y=0,z=0,dx=1,dy=0},target_kind='BUILDING',allow_breach=true},{},clock)
            assert(done and not success and code=='PERMISSION_DENIED',detail)
        ''')

    def test_reclosed_access_reopens_once_and_missing_target_stops(self):
        self.lua.execute('''
            player.x=0;player.y=0;a.x=0.5;a.y=0.5
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(there)
            local door={opened=false,toggles=0}
            function door:getSquare() return here end
            function door:isOpen() return self.opened end;door.IsOpen=door.isOpen
            function door:isLocked() return false end
            function door:isLockedByKey() return false end
            function door:isLockedByPadlock() return false end
            function door:getLockedByCode() return 0 end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function door:ToggleDoor() self.opened=not self.opened;self.toggles=self.toggles+1 end
            function here:getDoorTo(other) if other==there then return door end end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(payload,detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and door.opened and door.toggles==1)
            door.opened=false
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(not result.done and door.opened and door.toggles==2)
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+200)
            assert(not result.done and door.opened and door.toggles==2)
            function here:getDoorTo() return nil end
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+300)
            assert(result.done and not result.success and door.toggles==2)
        ''')

    def test_closed_door_approach_switches_to_opposite_side_after_no_progress(self):
        self.lua.execute('''
            a.x=-1.5;a.y=0.5
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local door={opened=false,locked=false,square=here,calls=0}
            function door:getSquare() return self.square end
            function door:isOpen() return self.opened end;door.IsOpen=door.isOpen
            function door:isLocked() return false end
            function door:isLockedByKey() return false end
            function door:isLockedByPadlock() return false end
            function door:getLockedByCode() return 0 end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function door:ToggleDoor() self.opened=true;self.calls=self.calls+1 end
            function here:getDoorTo(other) if other==there then return door end end
            local payload={edge={x=0,y=0,z=0,dx=1,dy=0},window=false,started_at=clock}
            local runtime={}
            local done,ok=Access.perform(a,payload,clock,runtime)
            assert(not done and ok and a.destination.x==0.5 and a.destination.y==0.5)
            done,ok=Access.perform(a,payload,clock+6100,runtime)
            assert(not done and ok and a.destination.x==1.5 and a.destination.y==0.5)
            assert(runtime.access_approach_switched==true and door.calls==0)
        ''')

    def test_gain_access_uses_native_low_fence_climb_and_observed_crossing(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(here)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            IsoDirections={E='east',W='west',N='north',S='south'}
            function a:getCurrentSquare() return cell:getGridSquare(math.floor(self.x),math.floor(self.y),0) end
            IsoWindow={canClimbThroughHelper=function(who,start,finish,north)
                assert(who==a and start==here and finish==there and north==false)
                return true
            end}
            function here:isPlayerAbleToHopWallTo(direction,other)
                assert(direction=='east' and other==there)
                return true
            end
            function a:climbOverFence(direction) assert(direction=='east');self.x=1.5;self.climbs=(self.climbs or 0)+1 end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and result.success and result.code=='WORKING' and a.climbs==1)
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and result.success and result.code=='COMPLETE')
        ''')

    def test_unreachable_open_yard_door_falls_back_to_prepared_low_fence(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fenceThere=cell:getGridSquare(0,1,0)
            local door={square=here}
            function door:getSquare() return self.square end
            function door:isOpen() return true end;door.IsOpen=door.isOpen
            function here:getDoorTo(other) if other==there then return door end end
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==fenceThere then return fence end end
            nativeHop(here,fenceThere)
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='DOOR',detail)
            assert(#payload.alternates>=1 and payload.alternates[1].access_method=='FENCE')
            assert(require('GoblinSurvivor/GoblinCapabilities').serializable(payload))
            a.x=5.5
            local runtime={access_opened=true,cross_approach_started_at=clock-31000}
            local done,success,message,code=GainAccess.update(a,payload,runtime,clock)
            assert(not done and success and code=='MOVING_TO_TARGET',message)
            assert(payload.access_method=='FENCE' and #payload.alternates==0)
            assert(runtime.access_opened==nil and runtime.cross_approach_started_at==nil)
            assert(payload.allow_breach==false and payload.started_at==clock)
            a.x=0.5
            done,success,message,code=GainAccess.update(a,payload,runtime,clock+100)
            assert(done and not success and code=='UNSUPPORTED',message)
            assert(payload.access_method=='FENCE' and #payload.alternates==0)
        ''')

    def test_unreachable_open_yard_door_tries_second_open_door(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local near=cell:getGridSquare(0,0,0);local nearOther=cell:getGridSquare(1,0,0)
            local far=cell:getGridSquare(0,2,0);local farOther=cell:getGridSquare(1,2,0)
            local first={};local second={}
            function first:isOpen() return true end;first.IsOpen=first.isOpen
            function second:isOpen() return true end;second.IsOpen=second.isOpen
            function near:getDoorTo(other) if other==nearOther then return first end end
            function far:getDoorTo(other) if other==farOther then return second end end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='DOOR' and payload.edge.y==0,detail)
            assert(#payload.alternates==1 and payload.alternates[1].edge.y==2)
            assert(require('GoblinSurvivor/GoblinCapabilities').serializable(payload))
            a.x=5.5;a.y=5.5
            local runtime={access_opened=true,cross_approach_started_at=clock-31000}
            local done,success,message,code=GainAccess.update(a,payload,runtime,clock)
            assert(not done and success and code=='MOVING_TO_TARGET',message)
            assert(payload.access_method=='DOOR' and payload.edge.y==2)
            a.x=0.5;a.y=2.5
            done,success,message,code=GainAccess.update(a,payload,runtime,clock+100)
            assert(not done and success and code=='MOVING_TO_TARGET',message)
            a.x=1.5
            done,success,message,code=GainAccess.update(a,payload,runtime,clock+200)
            assert(done and success and code=='COMPLETE',message)
        ''')

    def test_many_access_routes_fit_persistent_payload_and_keep_explicit_breach(self):
        self.lua.execute('''
            local originalResolve=Access.resolveTargetScope
            local originalPrepare=Access.prepare
            local originalBreach=Access.prepareBreachWindow
            Access.resolveTargetScope=function() return {} end
            Access.prepare=function(owner,window,now,options)
                local routes={}
                for index=1,12 do
                    routes[index]={edge={x=index,y=window and 2 or 1,z=0,dx=1,dy=0},
                        window=window,started_at=now,priority=window and 5 or 2,
                        score=(window and 5 or 2)*100000+index}
                end
                return routes[1],'mock loaded routes',routes
            end
            Access.prepareBreachWindow=function(owner,now,options)
                return {edge={x=99,y=0,z=0,dx=1,dy=0},window=true,
                    breach=true,started_at=now,priority=8},'explicit breach'
            end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',
                {target={kind='BUILDING'},allow_breach=true})
            Access.resolveTargetScope=originalResolve
            Access.prepare=originalPrepare
            Access.prepareBreachWindow=originalBreach
            assert(payload and payload.access_method=='DOOR',detail)
            assert(#payload.alternates==15)
            assert(payload.alternates[15].access_method=='BREACH_WINDOW')
            assert(payload.alternates[15].anchor==nil)
            assert(require('GoblinSurvivor/GoblinCapabilities').serializable(payload))
        ''')

    def test_unknown_hoppable_type_is_not_assumed_to_be_low_fence(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local unknown={square=here}
            function unknown:getSquare() return self.square end
            function here:getHoppableTo(other) if other==there then return unknown end end
            local payload=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload==nil)
        ''')

    def test_non_hoppable_fence_is_rejected_at_route_selection(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            IsoDirections={E='east',W='west',N='north',S='south'}
            function here:isPlayerAbleToHopWallTo(direction,other) return false end
            function there:isPlayerAbleToHopWallTo(direction,other) return false end
            local payload=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload==nil)
        ''')

    def test_yard_fence_candidate_stays_within_owner_radius(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(12,12,0);local there=cell:getGridSquare(13,12,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            nativeHop(here,there)
            local payload=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload==nil)
        ''')

    def test_yard_door_candidate_stays_within_owner_radius(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local far=cell:getGridSquare(12,12,0)
            local farOther=cell:getGridSquare(13,12,0)
            local farDoor={}
            function farDoor:isOpen() return true end;farDoor.IsOpen=farDoor.isOpen
            function far:getDoorTo(other) if other==farOther then return farDoor end end
            local absent=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(absent==nil)
            local near=cell:getGridSquare(10,0,0)
            local nearOther=cell:getGridSquare(11,0,0)
            local nearDoor={}
            function nearDoor:isOpen() return true end;nearDoor.IsOpen=nearDoor.isOpen
            function near:getDoorTo(other) if other==nearOther then return nearDoor end end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='DOOR',detail)
            assert(payload.edge.x==10 and payload.edge.y==0)
            assert(#payload.alternates==0)
        ''')

    def test_low_fence_rechecks_safehouse_policy_before_native_climb(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            nativeHop(here,there)
            IsoDirections={E='east',W='west',N='north',S='south'}
            function a:climbOverFence(direction) self.climbs=(self.climbs or 0)+1 end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            SafeHouse={getSafeHouse=function(square)
                return {playerAllowed=function(self,username) return false end}
            end}
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(result.done and not result.success and result.code=='PERMISSION_DENIED')
            assert(a.climbs==nil)
        ''')

    def test_low_fence_rejects_native_hop_precondition_without_claiming_work(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            nativeHop(here,there)
            IsoDirections={E='east',W='west',N='north',S='south'}
            function a:getCurrentSquare() return here end
            IsoWindow={canClimbThroughHelper=function() return true end}
            function a:climbOverFence(direction) self.climbs=(self.climbs or 0)+1 end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            function here:isPlayerAbleToHopWallTo(direction,other)
                assert(direction=='east' and other==there)
                return false
            end
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(result.done and not result.success and result.code=='BLOCKED')
            assert(a.climbs==nil)
        ''')

    def test_low_fence_rejects_native_passage_precondition_without_climbing(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            function here:isPlayerAbleToHopWallTo(direction,other) return true end
            IsoDirections={E='east',W='west',N='north',S='south'}
            function a:getCurrentSquare() return here end
            IsoWindow={canClimbThroughHelper=function(who,start,finish,north)
                assert(who==a and start==here and finish==there and north==false)
                return false
            end}
            function a:climbOverFence(direction) self.climbs=(self.climbs or 0)+1 end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(result.done and not result.success and result.code=='BLOCKED')
            assert(a.climbs==nil)
        ''')

    def test_low_fence_refuses_missing_native_preflight_methods(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            nativeHop(here,there)
            IsoDirections={E='east',W='west',N='north',S='south'}
            function a:climbOverFence(direction) self.climbs=(self.climbs or 0)+1 end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(result.done and not result.success and result.code=='UNSUPPORTED')
            function a:getCurrentSquare() return here end
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and not result.success and result.code=='UNSUPPORTED')
            IsoWindow={canClimbThroughHelper=function() return true end}
            here.isPlayerAbleToHopWallTo=nil
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+200)
            assert(result.done and not result.success and result.code=='UNSUPPORTED')
            assert(a.climbs==nil)
        ''')

    def test_low_fence_approach_switches_side_then_reports_no_path(self):
        self.lua.execute('''
            player.x=0;player.y=0;a.x=4.5;a.y=0.5
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            nativeHop(here,there)
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            local runtime={}
            local done,success,message,code=GainAccess.update(a,payload,runtime,clock)
            assert(not done and success and code=='MOVING_TO_TARGET',message)
            assert(a.destination.x==1.5)
            done,success,message,code=GainAccess.update(a,payload,runtime,clock+6100)
            assert(not done and success and code=='MOVING_TO_TARGET',message)
            assert(a.destination.x==0.5 and runtime.fence_approach_switched==true)
            done,success,message,code=GainAccess.update(a,payload,runtime,clock+30100)
            assert(done and not success and code=='NO_PATH',message)
            assert(a.climbs==nil)
        ''')

    def test_low_fence_requires_actor_current_square_before_native_call(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
            nativeHop(here,there)
            IsoDirections={E='east',W='west',N='north',S='south'}
            function a:getCurrentSquare() return nil end
            function a:climbOverFence(direction) self.climbs=(self.climbs or 0)+1 end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(result.done and not result.success and result.code=='BLOCKED')
            assert(a.climbs==nil)
        ''')

    def test_yard_route_discovers_constructed_locked_gate_and_observes_crossing(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local gate={square=there,opened=false,locked=true,keyLocked=true,syncs=0,silent=0}
            function gate:getSquare() return self.square end
            function gate:getNorth() return false end
            function gate:isDoor() return true end
            function gate:isOpen() return self.opened end;gate.IsOpen=gate.isOpen
            function gate:isLocked() return self.locked end
            function gate:setLocked(value) self.locked=value end
            function gate:isLockedByKey() return self.keyLocked end
            function gate:setLockedByKey(value) self.keyLocked=value end
            function gate:isLockedByPadlock() return false end
            function gate:getLockedByCode() return 0 end
            function gate:getKeyId() return 42 end
            function gate:isBarricaded() return false end
            function gate:isDestroyed() return false end
            function gate:syncIsoObject() self.syncs=self.syncs+1 end
            function gate:ToggleDoorSilent() self.silent=self.silent+1;self.opened=true end
            function gate:ToggleDoor() error('actor-taking toggle must not be used') end
            there.objects={gate}
            local denied=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(denied==nil and not gate.opened and gate.syncs==0)
            function a.inv:haveThisKeyId(id) assert(id==42);return {getFullType=function() return 'Base.Key1' end} end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='DOOR',detail)
            assert(payload.edge.x==0 and payload.edge.y==0 and payload.edge.dx==1)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and result.success and result.code=='MOVING_TO_TARGET')
            assert(gate.opened and not gate.locked and not gate.keyLocked)
            assert(gate.silent==1 and gate.syncs>=2)
            a.x=1.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and result.success and result.code=='COMPLETE')
        ''')

    def test_keyed_door_never_opens_when_native_unlock_did_not_clear_lock(self):
        self.lua.execute('''
            function a.inv:haveThisKeyId() return {} end
            local function makeDoor()
                local d={opened=false,locked=true,keyLocked=true,toggles=0}
                function d:getSquare() return target.square end
                function d:isOpen() return self.opened end
                function d:isLocked() return self.locked end
                function d:isLockedByKey() return self.keyLocked end
                function d:isLockedByPadlock() return false end
                function d:getLockedByCode() return 0 end
                function d:getKeyId() return 42 end
                function d:isBarricaded() return false end
                function d:isDestroyed() return false end
                function d:setLocked(v) self.locked=v end
                function d:setLockedByKey(v) self.keyLocked=v end
                function d:syncIsoObject() end
                function d:ToggleDoorSilent() self.opened=true;self.toggles=self.toggles+1 end
                return d
            end
            for _,failure in ipairs({'noop','throw','unreadable'}) do
                for _,field in ipairs({'locked','keyLocked'}) do
                    local door=makeDoor()
                    local setter=field=='locked' and 'setLocked' or 'setLockedByKey'
                    local getter=field=='locked' and 'isLocked' or 'isLockedByKey'
                    door[setter]=function(self,value)
                        if failure=='throw' then error('native mutation failed') end
                        if failure=='unreadable' then
                            self[field]=value
                            self[getter]=function() error('native read failed') end
                        end
                    end
                    local opened,detail=Access.open(a,door,false)
                    assert(not opened and door.toggles==0 and not door.opened,
                        failure..' '..field..' must not reach silent toggle: '..tostring(detail))
                end
            end
            local valid=makeDoor()
            assert(Access.open(a,valid,false) and valid.toggles==1)
            assert(not valid.locked and not valid.keyLocked)
            -- A failed sibling panel must also prevent the native group toggle.
            local first,second=makeDoor(),makeDoor()
            function second:setLocked(v) end
            local groupToggles=0
            IsoDoor={getDoubleDoorIndex=function() return 1 end,
                getDoubleDoorObject=function(_,i) return i==1 and first or second end,
                toggleDoubleDoor=function() groupToggles=groupToggles+1 end}
            assert(not Access.open(a,first,false))
            assert(not first.opened and not second.opened and second.locked and groupToggles==0)
            -- Retrying after partial unlock must not bypass the sibling merely
            -- because the selected panel is already unlocked.
            assert(not first.locked and not first.keyLocked)
            assert(not Access.open(a,first,false) and groupToggles==0)
        ''')

    def test_ordinary_key_does_not_erase_padlock_or_combination_lock(self):
        self.lua.execute('''
            local door={opened=false,locked=true,keyLocked=true,padlocked=false,code=0,mutations=0}
            function door:getSquare() return target.square end
            function door:isOpen() return self.opened end
            function door:isLocked() return self.locked end
            function door:isLockedByKey() return self.keyLocked end
            function door:isLockedByPadlock() return self.padlocked end
            function door:getLockedByCode() return self.code end
            function door:getKeyId() return 42 end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function door:setLocked(v) self.locked=v;self.mutations=self.mutations+1 end
            function door:setLockedByKey(v) self.keyLocked=v;self.mutations=self.mutations+1 end
            function door:setLockedByPadlock(v) self.padlocked=v;self.mutations=self.mutations+1 end
            function door:setLockedByCode(v) self.code=v;self.mutations=self.mutations+1 end
            function door:ToggleDoorSilent() self.opened=true end
            function door:syncIsoObject() end
            function a.inv:haveThisKeyId() return {} end
            door.padlocked=true
            assert(not Access.open(a,door,false))
            assert(door.padlocked and door.locked and door.keyLocked and door.mutations==0)
            door.padlocked=false;door.code=1234
            assert(not Access.open(a,door,false))
            assert(door.code==1234 and door.locked and door.keyLocked and door.mutations==0)
            -- A multi-panel door must be checked as a whole before changing
            -- even its otherwise ordinary selected panel.
            local other=door
            local panel={}
            for k,v in pairs(door) do panel[k]=v end
            panel.code=0
            IsoDoor={getDoubleDoorIndex=function() return 1 end,
                getDoubleDoorObject=function(_,i) return i==1 and panel or other end}
            assert(not Access.open(a,panel,false))
            assert(panel.locked and panel.keyLocked and panel.mutations==0)
        ''')

    def test_window_breach_requires_explicit_flag_and_observes_native_mutation(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(there)
            local window={opened=false,locked=true,smashed=false,square=here,calls=0}
            function window:getSquare() return self.square end
            function window:IsOpen() return self.opened end
            function window:isLocked() return self.locked end
            function window:isBarricaded() return false end
            function window:isDestroyed() return false end
            function window:isPermaLocked() return false end
            function window:isSmashed() return self.smashed end
            function window:smashWindow() self.smashed=true;self.calls=self.calls+1 end
            function window:syncIsoObject() self.synced=true end
            function here:getWindowTo(other) if other==there then return window end end
            local denied=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(not denied)
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',
                {target={kind='BUILDING'},allow_breach=true})
            assert(payload and payload.access_method=='BREACH_WINDOW',detail)
            a.x=3.5
            local approaching=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not approaching.done and approaching.code=='MOVING_TO_TARGET')
            assert(not window.smashed)
            a.x=0.5
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and result.success and result.code=='MOVING_TO_TARGET')
            assert(window.smashed and window.calls==1 and window.synced)
            a.x=1.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and result.success and result.code=='COMPLETE')
            local crowbar
            for _,value in ipairs(a.inv.items) do
                if value:getFullType()=='Base.Crowbar' then crowbar=value end
            end
            assert(require('GoblinSurvivor/GoblinTools').reserved(crowbar))
        ''')

    def test_building_scope_checks_far_perimeter_before_locked_near_door(self):
        self.lua.execute('''
            local building={};local room={x=0,y=0,x2=6,y2=0,z=0,building=building}
            function room:getX() return self.x end;function room:getY() return self.y end
            function room:getX2() return self.x2 end;function room:getY2() return self.y2 end
            function room:getZ() return self.z end;function room:getBuilding() return self.building end
            function building:getRooms() return list({room}) end
            for x=0,6 do local square=cell:getGridSquare(x,0,0);function square:getRoom() return room end end
            function accessDoor(locked)
                local d={locked=locked,opened=false}
                function d:isOpen() return self.opened end;d.IsOpen=d.isOpen
                function d:isLocked() return self.locked end
                function d:isLockedByKey() return false end
                function d:isLockedByPadlock() return false end
                function d:getLockedByCode() return 0 end
                function d:isBarricaded() return false end
                function d:isDestroyed() return false end
                return d
            end
            local west=cell:getGridSquare(-1,0,0);local westInside=cell:getGridSquare(0,0,0)
            local eastInside=cell:getGridSquare(6,0,0);local east=cell:getGridSquare(7,0,0)
            local locked=accessDoor(true);local unlocked=accessDoor(false)
            function west:getDoorTo(other) if other==westInside then return locked end end
            function eastInside:getDoorTo(other) if other==east then return unlocked end end
            player.x,player.y=-0.5,0.5
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='BUILDING'}})
            assert(payload and payload.access_method=='DOOR',detail)
            assert(payload.edge.x==6 and payload.edge.y==0,
                'whole-building selector did not prefer far unlocked perimeter door')
        ''')

    def test_access_prefers_alternate_unlocked_door_over_nearer_locked_door(self):
        self.lua.execute('''
            function accessDoor(locked)
                local d={locked=locked,opened=false}
                function d:isOpen() return self.opened end;d.IsOpen=d.isOpen
                function d:isLocked() return self.locked end
                function d:isLockedByKey() return false end
                function d:isLockedByPadlock() return false end
                function d:getLockedByCode() return 0 end
                function d:isBarricaded() return false end
                function d:isDestroyed() return false end
                return d
            end
            local near=cell:getGridSquare(0,0,0);local nearOther=cell:getGridSquare(1,0,0)
            local far=nearOther;local farOther=cell:getGridSquare(2,0,0)
            local locked=accessDoor(true);local unlocked=accessDoor(false)
            function near:getDoorTo(other) if other==nearOther then return locked end end
            function far:getDoorTo(other) if other==farOther then return unlocked end end
            player.x=0;player.y=0
            local payload,detail=Access.prepare(player,false,clock,{include_open=true})
            assert(payload,detail)
            assert(payload.edge.x==1 and payload.edge.y==0,'did not prefer alternate unlocked door: '
                ..tostring(payload.edge.x)..','..tostring(payload.edge.y))
        ''')

    def test_breach_requires_explicit_online_order(self):
        self.lua.execute('''
            assert(Policy.access(a,target))
            local ok,code=Policy.breach(a,target,'BUILDING',{})
            assert(not ok and code=='PERMISSION_DENIED')
            ok,code=Policy.breach(a,target,'BUILDING',{allow_breach=true,autonomous=true})
            assert(not ok and code=='PERMISSION_DENIED')
            ok,code=Policy.breach(a,target,'BUILDING',{allow_breach=true,offline=true})
            assert(not ok and code=='PERMISSION_DENIED')
            ok,code=Policy.breach(a,target,'BUILDING',{allow_breach=true})
            assert(ok and code=='COMPLETE')
        ''')

    def test_deterministic_chat_payload_is_semantic_and_breach_is_explicit_only(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/ChatBridge']=nil
            package.loaded['GoblinSurvivor/Config']={enabled=true}
            package.loaded['GoblinSurvivor/EventLog']={emit=function() end}
            package.loaded['GoblinSurvivor/Authority']={issue=function() end}
            package.loaded['GoblinSurvivor/EventHooks']={install=function() end}
            package.loaded['GoblinSurvivor/GoblinSpawner']={findForOwner=function() end}
            local Chat=require('GoblinSurvivor/ChatBridge')
            assert(Chat.directIntent('Goblin, gain access to the yard')=='GAIN_ACCESS')
            assert(Chat.directIntent('Goblin, access the yard')=='GAIN_ACCESS')
            assert(Chat.directIntent('Goblin, breach the room')==nil)
            local safe=Chat.accessPayload('Goblin, gain access to the vehicle')
            assert(safe.target.kind=='VEHICLE' and safe.allow_breach==false)
            local breach=Chat.accessPayload('Goblin, breach the room')
            assert(breach.target.kind=='ROOM' and breach.allow_breach==false)
            assert(breach.target.x==nil and breach.target.y==nil and breach.target.z==nil)
        ''')

    def test_qwen_bridge_accepts_semantic_kind_but_not_method_or_breach_authority(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinBridge']=nil
            package.loaded['GoblinSurvivor/Config']={enabled=true,npcId='dev.survivor.001'}
            package.loaded['GoblinSurvivor/Net']={safeTable=function() return true end,
                safeId=function(value) return type(value)=='string' end}
            package.loaded['GoblinSurvivor/Authority']={requires=function() return true end,
                consume=function() return true end,consumeOffline=function() return false end}
            package.loaded['GoblinSurvivor/GoblinSpawner']={findByNpcId=function(id) return a end}
            package.loaded['GoblinSurvivor/GoblinBody']={owner=function() return 'horse' end,
                say=function() end}
            executed={};response_status=nil
            package.loaded['GoblinSurvivor/GoblinBrain']={execute=function(message,body)
                assert(body==a);executed[#executed+1]=message;return true,'accepted'
            end}
            bridge_message={protocol=1,request_id='kind-only',timestamp_ms=1,
                type='command.npc_action',npc_id='dev.survivor.001.horse',owner='horse',
                action='GAIN_ACCESS',target={kind='BUILDING'},authority_token='grant-one'}
            package.loaded['GoblinSurvivor/IPC']={isReady=function() return true end,
                listReady=function() return {'one'} end,
                readReady=function() return bridge_message end,
                writeResponse=function(id,status) response_status=status end,
                acknowledge=function() end,archive=function() end,deadletter=function() end}
            local Bridge=require('GoblinSurvivor/GoblinBridge');Bridge.tick()
            assert(#executed==1 and executed[1].target.kind=='BUILDING' and response_status=='accepted')

            bridge_message={protocol=1,request_id='method-choice',timestamp_ms=2,
                type='command.npc_action',npc_id='dev.survivor.001.horse',owner='horse',
                action='GAIN_ACCESS',target={kind='CROWBAR'},authority_token='grant-two'}
            Bridge.tick();assert(#executed==1 and response_status=='rejected')
            bridge_message={protocol=1,request_id='model-breach',timestamp_ms=3,
                type='command.npc_action',npc_id='dev.survivor.001.horse',owner='horse',
                action='GAIN_ACCESS',target={kind='BUILDING'},allow_breach=true,
                authority_token='grant-three'}
            Bridge.tick();assert(#executed==1 and response_status=='rejected')
        ''')

    def test_other_player_safehouse_denies_access_and_breach(self):
        self.lua.execute('''
            SafeHouse={getSafeHouse=function(square)
                return {playerAllowed=function(self,username) return username=='unicorn' end}
            end}
            local ok,code=Policy.access(a,target)
            assert(not ok and code=='PERMISSION_DENIED')
            ok,code=Policy.breach(a,target,'BUILDING',{allow_breach=true})
            assert(not ok and code=='PERMISSION_DENIED')
        ''')

    def test_vehicle_breach_fails_closed_and_nonempty_container_is_protected(self):
        self.lua.execute('''
            local ok,code=Policy.breach(a,target,'VEHICLE',{allow_breach=true})
            assert(not ok and code=='UNSUPPORTED')
            function target:getContainer() return {getItems=function() return list({item('Base.Axe')}) end} end
            ok,code=Policy.breach(a,target,'CONTAINER',{allow_breach=true})
            assert(not ok and code=='PERMISSION_DENIED')
            function target:getContainer() return {getItems=function() return list({}) end} end
            ok,code=Policy.breach(a,target,'CONTAINER',{allow_breach=true})
            assert(ok and code=='COMPLETE')
        ''')


if __name__ == "__main__":
    unittest.main()
