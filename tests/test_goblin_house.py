from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class HouseAccessTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / part / "?.lua").as_posix() for part in ("shared", "server", "client")
        )
        self.lua.execute('package.path=paths..";"..package.path')
        for name in ("goblin_fixture.lua", "work_fixture.lua", "jobs_fixture.lua"):
            self.lua.execute((ROOT / "tests/lua" / name).read_text())

    def run_lua(self, source):
        self.lua.execute(source)

    def test_order_requires_owner_inside_exact_building_and_scans_multifloor_perimeter(self):
        self.run_lua(
            """
            player.x,player.y,player.z=20.5,20.5,0
            local missing,why=Curtains.prepare(a,player,{})
            assert(not missing and why:find('inside a house'))
            player.x,player.y=0.5,0.5
            local upper={x=0,y=0,x2=2,y2=2,z=1,building=houseBuilding}
            function upper:getX() return self.x end;function upper:getY() return self.y end
            function upper:getX2() return self.x2 end;function upper:getY2() return self.y2 end
            function upper:getZ() return self.z end;function upper:getBuilding() return self.building end
            function upper:isInside() return true end
            houseRooms={houseRoom,upper}
            local upperCurtain=curtain(1,1,1)
            local payload,detail=Curtains.prepare(a,player,{})
            assert(payload and payload.bounds and payload.bounds.max_z==1 and payload.target_id)
            assert(type(payload.house_id)=='string' and type(payload.curtain_id)=='number')
            assert(type(payload.bounds.x)=='number' and payload.bounds.x2>=2)
            -- The target is exact runtime state, not a coordinate retarget.
            Curtains.targets[a]=nil
            local done,ok=Curtains.update(a,payload,job(),clock)
            assert(done and not ok)
            """
        )

    def test_native_isoroom_and_isobuilding_wrappers_normalize_to_defs(self):
        self.run_lua(
            """
            local nativeBuilding={}
            function nativeBuilding:getDef() return houseBuilding end
            local nativeRoom={}
            function nativeRoom:getRoomDef() return houseRoom end
            function nativeRoom:getBuilding() return nativeBuilding end
            function nativeRoom:isInside(x,y,z) return x==0 and y==0 and z==0 end
            local ownerSquare=cell:getGridSquare(0,0,0)
            function ownerSquare:getRoom() return nativeRoom end
            player.x,player.y,player.z=0.5,0.5,0
            local c=curtain(1)
            local payload,detail=Curtains.prepare(a,player,{})
            assert(payload and payload.house_id and detail:find('all open curtains'))
            """
        )

    def test_each_close_rescans_and_reports_unreachable_partial(self):
        self.run_lua(
            """
            player.x,player.y=0.5,0.5
            local first=curtain(2);local second=curtain(5)
            local payload=Curtains.prepare(a,player,{})
            assert(payload)
            local j=job()
            local done,ok=Curtains.update(a,payload,j,clock)
            assert(not done and first.opened and second.opened)
            first.square.blocked=true
            done,ok=Curtains.update(a,payload,j,clock+45001)
            assert(not done and not ok or not done and ok)
            first.square.blocked=false
            a.x=4.5
            done,ok=Curtains.update(a,payload,j,clock+46000)
            assert(done and not ok and payload.completed==1 and payload.skipped==1)
            assert(not second.opened)
            """
        )

    def test_partially_streamed_building_never_claims_full_completion(self):
        self.run_lua(
            """
            function houseBuilding:isFullyStreamedIn() return false end
            player.x,player.y=0.5,0.5
            local c=curtain(1)
            local payload=Curtains.prepare(a,player,{})
            assert(payload and payload.partial_house==true)
            local done,ok,detail=Curtains.update(a,payload,job(),clock)
            assert(done and not ok and not c.opened and detail:find('unloaded'))
            """
        )

    def test_disappearing_final_target_does_not_toggle_a_new_distant_target_same_tick(self):
        self.run_lua(
            """
            player.x,player.y=0.5,0.5
            local first=curtain(1);local far=curtain(5)
            local removed=false
            function first:canInteractWith(who)
                if not removed then
                    removed=true
                    self.square.objects={}
                end
                return true
            end
            local payload=Curtains.prepare(a,player,{})
            assert(payload and payload.target_id)
            local j=job()
            local done,ok=Curtains.update(a,payload,j,clock)
            assert(not done and ok and removed)
            assert(first.calls==0 and far.calls==0)
            -- The next tick may validate the newly selected target, but it
            -- must not have been toggled in the same frame as the removal.
            a.x,a.y=5.5,0.5
            done,ok=Curtains.update(a,payload,j,clock+1000)
            assert(done and not ok and far.calls==1 and not far.opened)
            """
        )

    def test_route_uses_native_next_edge_and_closes_only_exact_exterior_door(self):
        self.run_lua(
            """
            Access=require('GoblinSurvivor/GoblinAccess')
            local inside=cell:getGridSquare(6,1,0);local outside=cell:getGridSquare(7,1,0)
            local door={opened=false,calls=0}
            function door:isOpen() return self.opened end
            function door:isLocked() return false end;function door:isBarricaded() return false end
            function door:isDestroyed() return false end;function door:isLockedByKey() return false end
            function door:ToggleDoor(who) self.calls=self.calls+1;self.opened=not self.opened end
            function inside:getDoorTo(other) if other==outside then return door end end
            local behavior={}
            function behavior:pathNextIsSet() return true end
            function behavior:pathNextX() return 7 end;function behavior:pathNextY() return 1 end
            function a:getPathFindBehavior2() return behavior end
            a.x,a.y=6.5,1.5
            local scope={building=houseBuilding}
            local goal={x=8.5,y=1.5,z=0}
            Access.update(a,goal,clock,scope)
            assert(door.opened and door.calls==1)
            a.x=7.5
            Access.update(a,goal,clock+1000,scope)
            assert(not door.opened and door.calls==2)
            -- Replacing the exact object cannot cause a remote/replacement close.
            local replacement={opened=true,calls=0}
            function replacement:isOpen() return self.opened end
            function replacement:ToggleDoor() self.calls=self.calls+1;self.opened=false end
            function inside:getDoorTo(other) if other==outside then return replacement end end
            a.x=2.5;Access.tick(a,clock+2000)
            assert(replacement.calls==0 and replacement.opened)
            """
        )

    def test_initially_open_interior_door_is_preserved_but_goblin_opened_interior_is_restored(self):
        self.run_lua(
            """
            Access=require('GoblinSurvivor/GoblinAccess')
            local left=cell:getGridSquare(2,4,0);local right=cell:getGridSquare(3,4,0)
            local openDoor={opened=true,calls=0}
            function openDoor:isOpen() return self.opened end
            function openDoor:ToggleDoor() self.calls=self.calls+1;self.opened=not self.opened end
            function left:getDoorTo(other) if other==right then return openDoor end end
            a.x,a.y=2.5,4.5
            local scope={building=houseBuilding};local goal={x=5.5,y=4.5,z=0}
            Access.update(a,goal,clock,scope);a.x=3.5;Access.update(a,goal,clock+1000,scope)
            assert(openDoor.opened and openDoor.calls==0)
            local closedDoor={opened=false,calls=0}
            function closedDoor:isOpen() return self.opened end
            function closedDoor:isLocked() return false end
            function closedDoor:isBarricaded() return false end
            function closedDoor:isDestroyed() return false end
            function closedDoor:isLockedByKey() return false end
            function closedDoor:ToggleDoor() self.calls=self.calls+1;self.opened=not self.opened end
            local left2=cell:getGridSquare(4,4,0);local right2=cell:getGridSquare(5,4,0)
            function left2:getDoorTo(other) if other==right2 then return closedDoor end end
            a.x,a.y=4.5,4.5;Access.update(a,goal,clock+2000,scope)
            assert(closedDoor.opened and closedDoor.calls==1)
            -- Preserve the original closed provenance while the Goblin
            -- waits on the near side for more than one Access cooldown.
            Access.update(a,goal,clock+2500,scope)
            a.x=5.5;Access.update(a,goal,clock+3500,scope)
            assert(not closedDoor.opened and closedDoor.calls==2)
            """
        )

    def test_owner_traffic_and_client_side_writes_are_refused(self):
        self.run_lua(
            """
            Access=require('GoblinSurvivor/GoblinAccess')
            local inside=cell:getGridSquare(6,2,0);local outside=cell:getGridSquare(7,2,0)
            local door={opened=false,calls=0}
            function door:isOpen() return self.opened end
            function door:isLocked() return false end;function door:isBarricaded() return false end
            function door:isDestroyed() return false end;function door:isLockedByKey() return false end
            function door:getX() return 6 end;function door:getY() return 2 end;function door:getZ() return 0 end
            function door:ToggleDoor() self.calls=self.calls+1;self.opened=not self.opened end
            function inside:getDoorTo(other) if other==outside then return door end end
            -- Native doors are static IsoObjects and can be present in
            -- square:getObjects(); they are not moving traffic.
            inside.objects[#inside.objects+1]=door
            a.x,a.y=6.5,2.5;player.x,player.y=6.5,2.5
            local scope={building=houseBuilding};local goal={x=8.5,y=1.5,z=0}
            Access.update(a,goal,clock,scope);assert(door.opened)
            a.x=7.5;Access.update(a,goal,clock+1000,scope)
            assert(door.opened and door.calls==1)
            player.x,player.y=20.5,20.5
            Access.update(a,goal,clock+2000,scope)
            assert(not door.opened and door.calls==2)
            clientMode=true
            assert(not Access.open(a,door,false) and door.calls==2)
            clientMode=false
            """
        )


if __name__ == "__main__":
    unittest.main()
