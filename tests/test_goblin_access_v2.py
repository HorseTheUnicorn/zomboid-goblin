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
        ''')

    def test_gain_access_is_registered_and_opens_real_selected_door(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(here)
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
            assert(a.destination and a.destination.x==1.5 and a.destination.y==0.5)
            a.x=1.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(not result.done and result.success and result.code=='MOVING_TO_TARGET')
            a.x=0.5
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+200)
            assert(result.done and result.success and result.code=='COMPLETE')
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
            function a:climbOverFence(direction) assert(direction=='east');self.x=1.5;self.climbs=(self.climbs or 0)+1 end
            local payload,detail=Jobs.prepare(a,player,'GAIN_ACCESS',{target={kind='YARD'}})
            assert(payload and payload.access_method=='FENCE',detail)
            local result=Jobs.update(a,'GAIN_ACCESS',payload,clock)
            assert(not result.done and result.success and result.code=='WORKING' and a.climbs==1)
            result=Jobs.update(a,'GAIN_ACCESS',payload,clock+100)
            assert(result.done and result.success and result.code=='COMPLETE')
        ''')

    def test_low_fence_rechecks_safehouse_policy_before_native_climb(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            local fence={square=here}
            function fence:getSquare() return self.square end
            function fence:isTallHoppable() return false end
            function here:getHoppableTo(other) if other==there then return fence end end
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

    def test_window_breach_requires_explicit_flag_and_observes_native_mutation(self):
        self.lua.execute('''
            player.x=0;player.y=0
            local here=cell:getGridSquare(0,0,0);local there=cell:getGridSquare(1,0,0)
            installBuilding(here)
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
            local safe=Chat.accessPayload('Goblin, gain access to the vehicle')
            assert(safe.target.kind=='VEHICLE' and safe.allow_breach==false)
            local breach=Chat.accessPayload('Goblin, breach the room')
            assert(breach.target.kind=='ROOM' and breach.allow_breach==true)
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
