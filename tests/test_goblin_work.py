"""Behavior tests at the engine boundary, including refused and partial operations."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[1]
LUA=ROOT/'mod/Contents/mods/GoblinSurvivor/42/media/lua'


class CompanionWorkTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths=';'.join((LUA/scope/'?.lua').as_posix() for scope in ('shared','server','client'))
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ('goblin_fixture.lua','work_fixture.lua'):
            self.lua.execute((ROOT/'tests/lua'/filename).read_text())

    def test_looting_walks_before_transfer_and_honors_action_time(self):
        self.lua.execute('''
            sq=cell:getGridSquare(4,0,0); inv=container({item('Base.Plank')})
            sq.objects={{getContainer=function() return inv end}}
            ok,detail,moved,done=Loot.collect(a,{},clock)
            assert(moved==0 and not done and #inv.items==1 and a.pathCalls==1)
            a.x=3.5
            Loot.collect(a,{},clock+1000)
            assert(#inv.items==1)
            Loot.collect(a,{},clock+2500)
            assert(#inv.items==0 and #a.inv.items==1)
            ok,detail,moved,done=Loot.collect(a,{},clock+3000)
            assert(done and moved==1)
        ''')

    def test_autonomous_loot_abandons_immobile_client_owned_target_for_exploration(self):
        self.lua.execute('''
            sq=cell:getGridSquare(4,0,0); inv=container({item('Base.Plank'),item('Base.Nails')})
            sq.objects={{getContainer=function() return inv end}}
            local nextSquare=cell:getGridSquare(6,0,0)
            local nextInv=container({item('Base.TinCan')})
            nextSquare.objects={{getContainer=function() return nextInv end}}
            local payload={autonomous=true,loot_focus='surprise'}
            local ok,detail,moved,done=Loot.collect(a,payload,clock)
            assert(ok and not done and #inv.items==2 and a.destination.x==4.5)
            local job=Loot.jobs[a]
            a.x=1.0
            Loot.collect(a,payload,clock+8000)
            assert(job.explore==nil and job.progressAt==clock+8000)
            Loot.collect(a,payload,clock+19000)
            assert(job.explore==nil and #inv.items==2)
            ok,detail,moved,done=Loot.collect(a,payload,clock+20000)
            assert(ok and not done and moved==0 and job.skipped[inv.items[1]])
            assert(job.skippedSquares[sq])
            assert(job.explore~=nil and job.sources==nil)
            assert(a.destination.x~=4.5 or a.destination.y~=0.5)
            assert(a.data.GoblinLootStatus=='exploring for supplies')
            assert(#inv.items==2 and #a.inv.items==0)
            job.explore=nil
            Loot.collect(a,payload,clock+20100)
            assert(#job.sources==1 and job.sources[1].square==nextSquare)
        ''')

    def test_autonomous_loot_ends_after_area_stall_and_backs_off(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            local payload={autonomous=true,loot_focus='surprise'}
            local source=cell:getGridSquare(4,0,0)
            source.objects={{getContainer=function()
                return container({item('Base.Plank')}) end}}
            local ok,detail,moved,done=Loot.collect(a,payload,clock)
            assert(ok and not done)
            ok,detail,moved,done=Loot.collect(a,payload,clock+30001)
            assert(ok and done and moved==0)
            assert(detail=='no reachable supplies; returning to owner')
            assert(Loot.jobs[a]==nil and Loot.autonomousBlocked(a,clock+30001))
            a.data.GoblinTask='FOLLOW'
            Autonomy.update(a,clock+30001)
            Autonomy.update(a,clock+60001)
            assert(a.data.GoblinTask=='FOLLOW','do not immediately repeat a blocked scan')
            assert(not Loot.autonomousBlocked(a,clock+90001))
        ''')

    def test_autonomous_no_progress_spans_requeued_loot_jobs(self):
        self.lua.execute('''
            local payload={autonomous=true,loot_focus='surprise'}
            local ok,detail,moved,done=Loot.collect(a,payload,clock)
            assert(ok and not done and Loot.activity[a])
            Loot.clear(a) -- a short scan completed; the owner remained idle
            ok,detail,moved,done=Loot.collect(a,payload,clock+15000)
            assert(ok and not done and not Loot.autonomousBlocked(a,clock+15000))
            Loot.clear(a)
            ok,detail,moved,done=Loot.collect(a,payload,clock+30001)
            assert(ok and done and detail=='no reachable supplies; returning to owner')
            assert(Loot.autonomousBlocked(a,clock+30001))
        ''')

    def test_autonomous_patrol_cursor_survives_follow_handoff(self):
        self.lua.execute('''
            local Explore=require('GoblinSurvivor/GoblinExplore')
            local first={autonomous=true}; local job={}
            Explore.update(a,first,job,clock)
            local waypoint=job.explore
            assert(waypoint and first.search_cursor==1)
            Loot.clear(a) -- FOLLOW replaces the LOOT payload and job
            local second={autonomous=true}; job={}
            Explore.update(a,second,job,clock+90000)
            assert(job.explore and second.search_cursor==2)
            assert(job.explore.x~=waypoint.x or job.explore.y~=waypoint.y)
        ''')

    def test_defense_override_replaces_real_legacy_body_weapon(self):
        # Other work fixtures stub Body. Exercise the actual equipment module
        # before/after the startup override so source-only audits cannot mistake
        # the legacy pistol implementation for the initialized weapon policy.
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinBody']=nil
            local realBody=require('GoblinSurvivor/GoblinBody')
            local Config=require('GoblinSurvivor/Config')
            a.data.goblin_owned=true
            a.data.GoblinID=Config.npcId..'.horse'
            local legacy=realBody.ensureWeapon
            local defense=require('GoblinSurvivor/GoblinDefense')
            defense.install()
            assert(realBody.ensureWeapon~=legacy)
            local ok,detail,weapon=realBody.ensureWeapon(a)
            assert(ok and weapon:getFullType()=='Base.DoubleBarrelShotgun')
            assert(a.hand==weapon and a.data.GoblinWeaponType=='Base.DoubleBarrelShotgun')
            assert(not World.materials(a,{['Base.Pistol3']=1}))
            assert(not Loot.hasCargo(a))
        ''')

    def test_body_snapshot_reads_native_simulation_owner_without_writing_it(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinBody']=nil
            local realBody=require('GoblinSurvivor/GoblinBody')
            local Config=require('GoblinSurvivor/Config')
            local nativePlayer={getUsername=function() return 'unicorn' end}
            a.data.GoblinNPC=true
            a.data.goblin_owned=true
            a.data.GoblinID=Config.npcId..'.horse'
            a.data.GoblinOwner='horse'
            a.data.GoblinTask='FOLLOW'
            a.engineOwner={}
            function a:getOwnerPlayer() return nativePlayer end
            local clientOwned=realBody.snapshot(a)
            assert(clientOwned.navigation.simulation_owner=='client')
            assert(clientOwned.navigation.native_owner_player=='unicorn')
            assert(clientOwned.navigation.current_task=='FOLLOW')
            assert(a.engineOwner~=nil) -- telemetry is read-only

            a.engineOwner=nil
            function a:getOwnerPlayer() return nil end
            local serverOwned=realBody.snapshot(a)
            assert(serverOwned.navigation.simulation_owner=='server')
            assert(serverOwned.navigation.native_owner_player==nil)
        ''')

    def test_transfer_failure_rolls_back_without_duplication(self):
        self.lua.execute('''
            sq=cell:getGridSquare(0,0,0); value=item('Base.Nails'); inv=container({value})
            a.inv.reject=true
            assert(not World.take(a,{square=sq,container=inv,item=value}))
            assert(#inv.items==1 and inv.items[1]==value and #a.inv.items==0)
        ''')

    def test_material_reservation_reconciles_an_unreadable_post_remove_state(self):
        self.lua.execute('''
            local value=item('Base.Plank')
            a.inv=container({value})
            local originalRemove=a.inv.Remove
            function a.inv:Remove(item)
                originalRemove(self,item)
                self.unreadable=true
            end
            function a.inv:contains(item)
                if self.unreadable then error('native contains unavailable') end
                for _,current in ipairs(self.items) do if current==item then return true end end
                return false
            end
            function a.inv:getItems()
                if self.unreadable then error('inventory unreadable') end
                return list(self.items)
            end
            assert(not World.reserve(a,{value}))
            assert(#a.inv.items==0 and World.pendingMaterials[a])
            assert(not World.reserve(a,{value})) -- no retry while state is unknown
            a.inv.unreadable=false
            assert(World.refund(a,{}))
            assert(#a.inv.items==1 and a.inv.items[1]==value)
            assert(World.pendingMaterials[a]==nil)
            assert(World.refund(a,{value}) and #a.inv.items==1)
        ''')

    def test_material_reservation_refunds_a_confirmed_post_remove_exception(self):
        self.lua.execute('''
            local value=item('Base.Plank')
            a.inv=container({value})
            local originalRemove=a.inv.Remove
            function a.inv:Remove(item)
                originalRemove(self,item)
                error('exception after removal')
            end
            assert(not World.reserve(a,{value}))
            assert(#a.inv.items==1 and a.inv.items[1]==value)
            assert(World.pendingMaterials[a]==nil)
        ''')

    def test_exact_container_pickup_rejects_failed_removal_even_if_list_unreadable(self):
        self.lua.execute('''
            local sq=cell:getGridSquare(0,0,0)
            local value=item('Base.Nails')
            local source=container({value})
            local obj={getContainer=function() return source end}
            sq.objects={obj}
            function source:Remove() self.unreadable=true end
            function source:getItems()
                if self.unreadable then error('inventory unreadable') end
                return list(self.items)
            end
            assert(not World.take(a,{square=sq,object=obj,container=source,item=value}))
            assert(source.items[1]==value and #a.inv.items==0)
        ''')

    def test_container_locked_after_selection_cannot_be_looted(self):
        self.lua.execute('''
            local sq=cell:getGridSquare(0,0,0)
            local value=item('Base.Nails')
            local source=container({value})
            local obj={locked=true,getContainer=function() return source end,
                isLocked=function(self) return self.locked end}
            sq.objects={obj}
            assert(not World.take(a,{square=sq,object=obj,container=source,item=value}))
            assert(#source.items==1 and source.items[1]==value and #a.inv.items==0)
        ''')

    def test_exact_container_pickup_uses_native_contains_after_removal(self):
        self.lua.execute('''
            local sq=cell:getGridSquare(0,0,0)
            local value=item('Base.Nails')
            local source=container({value})
            local obj={getContainer=function() return source end}
            sq.objects={obj}
            local removed,added=0,0
            sendRemoveItemFromContainer=function(c,i)
                assert(c==source and i==value);removed=removed+1 end
            sendAddItemToContainer=function(c,i)
                assert(c==a.inv and i==value);added=added+1 end
            local original=source.Remove
            function source:Remove(item)
                original(self,item);self.unreadable=true
            end
            function source:getItems()
                if self.unreadable then error('inventory unreadable') end
                return list(self.items)
            end
            assert(World.take(a,{square=sq,object=obj,container=source,item=value}))
            assert(#source.items==0 and a.inv.items[1]==value)
            assert(removed==1 and added==0) -- managed IsoZombie inventory is not a packet target
        ''')

    def test_source_sync_failure_keeps_exact_item_and_reports_failure(self):
        self.lua.execute('''
            local sq=cell:getGridSquare(0,0,0)
            local value=item('Base.Nails')
            local source=container({value})
            local obj={getContainer=function() return source end}
            sq.objects={obj}
            sendRemoveItemFromContainer=function() error('source network send failed') end
            sendAddItemToContainer=function() error('must not target zombie inventory') end
            assert(not World.take(a,{square=sq,object=obj,container=source,item=value}))
            assert(#source.items==0 and a.inv.items[1]==value)
        ''')

    def test_items_cannot_be_taken_through_walls_or_above_capacity(self):
        self.lua.execute('''
            sq=cell:getGridSquare(1,0,0); sq.blocked=true
            value=item('Base.Plank'); inv=container({value})
            assert(not World.take(a,{square=sq,container=inv,item=value}))
            sq.blocked=false; a.inv.full=true
            assert(not World.take(a,{square=sq,container=inv,item=value}))
            assert(#inv.items==1)
        ''')

    def test_diagonal_work_reach_rejects_a_blocked_corner(self):
        self.lua.execute('''
            local target=cell:getGridSquare(1,1,0)
            local east=cell:getGridSquare(1,0,0)
            local south=cell:getGridSquare(0,1,0)
            east.blocked=true
            south.blocked=true
            assert(not World.reachable(a,target))
            east.blocked=false
            assert(World.reachable(a,target))
            east.blocked=true
            local value=item('Base.Nails')
            local source=container({value})
            local object={getContainer=function() return source end}
            target.objects={object}
            assert(not World.take(a,{square=target,object=object,container=source,item=value}))
            assert(source.items[1]==value and #a.inv.items==0)
        ''')

    def test_diagonal_approach_candidate_requires_an_open_corner_route(self):
        self.lua.execute('''
            local target=cell:getGridSquare(5,5,0)
            target.occupied=true
            for dx=-1,1 do for dy=-1,1 do
                if dx~=0 or dy~=0 then
                    cell:getGridSquare(5+dx,5+dy,0).occupied=true
                end
            end end
            local diagonal=cell:getGridSquare(4,4,0)
            diagonal.occupied=false
            local west=cell:getGridSquare(4,5,0)
            local north=cell:getGridSquare(5,4,0)
            west.blocked=true
            north.blocked=true
            assert(World.approachCandidate(a,target,clock,false)==nil)
            west.blocked=false
            local candidate=World.approachCandidate(a,target,clock,false)
            assert(candidate and candidate.square==diagonal and candidate.ring==1)
        ''')

    def test_work_approach_expands_to_radius_two_without_mutating_the_target(self):
        self.lua.execute('''
            local target=cell:getGridSquare(5,5,0)
            local before=#target.objects
            for dx=-1,1 do for dy=-1,1 do
                cell:getGridSquare(5+dx,5+dy,0).occupied=true
            end end
            local candidate,detail=World.approachCandidate(a,target,clock,true)
            assert(candidate and candidate.ring==2 and candidate.interaction_target==target)
            assert(candidate.reason=='radius-2 staging approach' and #target.objects==before)
            local done,status=World.approach(a,target,clock)
            assert(not done and status=='walking to alternate work approach')
            assert(a.pathCalls==1 and #target.objects==before)
        ''')

    def test_work_approach_rejects_unreadable_occupancy_and_fire_state(self):
        self.lua.execute('''
            local target=cell:getGridSquare(5,5,0)
            local nearby={}
            for dx=-2,2 do for dy=-2,2 do
                nearby[#nearby+1]=cell:getGridSquare(5+dx,5+dy,0)
            end end
            for _,square in ipairs(nearby) do square.getMovingObjects=nil end
            assert(World.approachCandidate(a,target,clock,true)==nil)
            for _,square in ipairs(nearby) do
                function square:getMovingObjects() return list({}) end
                square.haveFire=nil
            end
            assert(World.approachCandidate(a,target,clock,true)==nil)
            for _,square in ipairs(nearby) do
                function square:haveFire() error('fire state unreadable') end
            end
            assert(World.approachCandidate(a,target,clock,true)==nil)
            for _,square in ipairs(nearby) do
                function square:haveFire() return false end
            end
            local candidate=World.approachCandidate(a,target,clock,true)
            assert(candidate and candidate.square==target)
        ''')

    def test_cached_work_approach_is_invalidated_if_occupancy_becomes_unreadable(self):
        self.lua.execute('''
            local target=cell:getGridSquare(5,5,0)
            local done=World.approach(a,target,clock)
            assert(not done and World.approaches[a].chosen.square==target)
            target.getMovingObjects=nil
            World.approach(a,target,clock+100)
            assert(World.approaches[a].chosen.square~=target)
        ''')

    def test_work_approach_keeps_one_valid_staging_square_while_actor_moves(self):
        self.lua.execute('''
            local target=cell:getGridSquare(5,5,0)
            for dx=-1,1 do for dy=-1,1 do
                cell:getGridSquare(5+dx,5+dy,0).occupied=true
            end end
            local done,status=World.approach(a,target,clock)
            assert(not done and status=='walking to alternate work approach')
            local firstX,firstY=a.destination.x,a.destination.y
            a.x,a.y=10.5,10.5
            World.approach(a,target,clock+250)
            assert(a.destination.x==firstX and a.destination.y==firstY)
            assert(a.pathCalls==1)
            cell:getGridSquare(math.floor(firstX),math.floor(firstY),0).occupied=true
            World.approach(a,target,clock+500)
            assert(a.destination.x~=firstX or a.destination.y~=firstY)
            assert(a.pathCalls==2)
        ''')

    def test_rejected_native_work_approach_tries_another_square(self):
        self.lua.execute('''
            local Motion=require('GoblinSurvivor/GoblinLocomotion')
            local target=cell:getGridSquare(5,5,0)
            local first=World.approachCandidate(a,target,clock,true)
            assert(first and first.square==target)
            local rejectedX,rejectedY=first.point.x,first.point.y
            local realPath=a.pathToLocationF
            function a:pathToLocationF(x,y,z)
                if x==rejectedX and y==rejectedY then
                    self.pathCalls=self.pathCalls+1
                    return false
                end
                return realPath(self,x,y,z)
            end
            local done,status=World.approach(a,target,clock)
            assert(not done and status=='retrying alternate work approach')
            assert(Motion.isBlacklisted(a,first.key,clock,'approach'))
            done,status=World.approach(a,target,clock+100)
            assert(not done and status=='walking to supplies/work')
            assert(a.destination and (a.destination.x~=rejectedX or a.destination.y~=rejectedY))
            assert(World.approaches[a].chosen.key~=first.key)
        ''')

    def test_delegated_work_approach_blacklists_stalled_square(self):
        self.lua.execute('''
            local Motion=require('GoblinSurvivor/GoblinLocomotion')
            Motion.controls=function() return false end
            local target=cell:getGridSquare(5,5,0)
            local done,status=World.approach(a,target,clock)
            local first=World.approaches[a].chosen.key
            assert(not done and status=='walking to supplies/work')
            -- Position updates, not accepted delegated path calls, reset the
            -- server's no-progress timer.
            a.x=0.8
            done,status=World.approach(a,target,clock+11000)
            assert(not done and not Motion.isBlacklisted(a,first,clock+11000,'approach'))
            done,status=World.approach(a,target,clock+22000)
            assert(not done and not Motion.isBlacklisted(a,first,clock+22000,'approach'))
            done,status=World.approach(a,target,clock+23100)
            assert(not done and status=='retrying alternate work approach')
            assert(Motion.isBlacklisted(a,first,clock+23100,'approach'))
            done,status=World.approach(a,target,clock+23200)
            assert(not done and status=='walking to supplies/work')
            assert(World.approaches[a].chosen.key~=first)
        ''')

    def test_rejected_work_approaches_stop_after_bounded_candidates(self):
        self.lua.execute('''
            local target=cell:getGridSquare(5,5,0)
            function a:pathToLocationF(x,y,z)
                self.pathCalls=self.pathCalls+1
                return false
            end
            local status
            for attempt=1,26 do
                local done
                done,status=World.approach(a,target,clock+attempt*100)
                assert(not done)
            end
            assert(status=='no accessible work square')
            assert(a.pathCalls==25)
            local done,nextStatus=World.approach(a,target,clock+2700)
            assert(not done and nextStatus=='no accessible work square' and a.pathCalls==25)
        ''')

    def test_build_consumes_materials_once_and_retains_hammer(self):
        self.lua.execute('''
            supplies(3,3); payload={kind='crate',x=1,y=0,z=0}
            assert(not Work.update(a,'BUILD',payload,clock))
            assert(#a.inv.items==7)
            assert(Work.update(a,'BUILD',payload,clock+5000))
            assert(#a.inv.items==1 and World.fullType(a.inv.items[1])=='Base.Hammer')
            assert(#cell:getGridSquare(1,0,0).objects==1 and a.data.GoblinWorkCompleted==1)
        ''')

    def test_missing_nails_cannot_create_a_free_barricade(self):
        self.lua.execute('''
            supplies(1,1); w=window(cell:getGridSquare(1,0,0))
            Work.update(a,'FORTIFY',{},clock); Work.update(a,'FORTIFY',{},clock+5000)
            assert(w.barr==nil and #a.inv.items==3 and a.data.GoblinWorkCompleted==nil)
        ''')

    def test_boarding_consumes_one_plank_and_two_nails(self):
        self.lua.execute('''
            supplies(1,2); w=window(cell:getGridSquare(1,0,0))
            Work.update(a,'FORTIFY',{},clock); Work.update(a,'FORTIFY',{},clock+5000)
            assert(w.barr:getNumPlanks()==1 and #a.inv.items==1)
            Work.update(a,'FORTIFY',{},clock+12000)
            assert(w.barr:getNumPlanks()==1)
        ''')

    def test_postmutation_barricade_error_does_not_refund_consumed_materials(self):
        self.lua.execute('''
            supplies(1,2)
            local target=window(cell:getGridSquare(1,0,0))
            local original=IsoBarricade.AddBarricadeToObject
            IsoBarricade.AddBarricadeToObject=function(object)
                local barr={planks=0}
                function barr:getNumPlanks() return self.planks end
                function barr:addPlank()
                    self.planks=self.planks+1
                    error('fault after native mutation')
                end
                object.barr=barr
                return barr
            end
            Work.update(a,'FORTIFY',{},clock)
            local done=Work.update(a,'FORTIFY',{},clock+5000)
            assert(done and target.barr:getNumPlanks()==1)
            assert(#a.inv.items==1)
            assert(a.data.GoblinWorkStatus:find('not duplicated'))
            IsoBarricade.AddBarricadeToObject=original
        ''')

    def test_material_reserve_and_refund_do_not_send_invalid_zombie_inventory_packets(self):
        self.lua.execute('''
            supplies(1,2)
            local removals,additions=0,0
            sendRemoveItemFromContainer=function() removals=removals+1 end
            sendAddItemToContainer=function() additions=additions+1 end
            local selected=assert(World.materials(a,{['Base.Plank']=1,['Base.Nails']=2}))
            assert(World.reserve(a,selected))
            assert(removals==0 and #a.inv.items==1)
            World.refund(a,selected)
            assert(additions==0 and #a.inv.items==4)
        ''')

    def test_loot_source_rechecks_safehouse_and_exact_container_at_pickup(self):
        self.lua.execute('''
            local sq=cell:getGridSquare(1,0,0)
            local inv=container({item('Base.Nails')})
            local object={getContainer=function() return inv end}
            sq.objects={object}
            local restricted=false
            SafeHouse={getSafeHouse=function(square)
                if square~=sq then return nil end
                return {playerAllowed=function(self,owner) return not restricted end}
            end}
            local sources=World.sources({x=0,y=0,z=0},2,function(i)
                return World.fullType(i)=='Base.Nails'
            end,a)
            assert(#sources==1)
            restricted=true
            assert(not World.take(a,sources[1]) and #inv.items==1)
            assert(#World.sources({x=0,y=0,z=0},2,function() return true end,a)==0)
            restricted=false
            sq.objects={}
            assert(not World.take(a,sources[1]) and #inv.items==1)
        ''')

    def test_postinsertion_build_error_does_not_refund_materials(self):
        self.lua.execute('''
            supplies(3,3)
            local square=cell:getGridSquare(0,0,0)
            local original=square.AddSpecialObject
            function square:AddSpecialObject(object)
                original(self,object)
                error('fault after native insertion')
            end
            local payload={kind='crate',north=false,x=0,y=0,z=0}
            Work.update(a,'BUILD',payload,clock)
            local done=Work.update(a,'BUILD',payload,clock+5000)
            assert(done and #square.objects==1 and #a.inv.items==1)
            assert(a.data.GoblinWorkStatus:find('not duplicated'))
        ''')

    def test_feral_names_survive_recovery_and_avoid_collisions(self):
        self.lua.execute('''
            I=require('GoblinSurvivor/GoblinIdentity')
            name=I.name('horse',{}); assert(name==I.name('horse',{}))
            assert(I.name('horse',{{name=name}})~=name)
            Spawner=require('GoblinSurvivor/GoblinSpawner')
            original=Spawner.ensureForPlayer(player,false)
            name=saved.records.horse.name
            online=list(); Spawner.ensureAll(false)
            assert(not original.removed)
            online=list({player}); recovered=Spawner.ensureForPlayer(player,false)
            assert(original==recovered and saved.records.horse.name==name and spawnCount==1)
        ''')

    def test_all_skills_work_without_player_xp_object(self):
        self.lua.execute('''
            I=require('GoblinSurvivor/GoblinIdentity'); levels={}
            Perks={None='none'}
            root={getParent=function() return 'none' end}
            skill={getParent=function() return root end}
            PerkFactory={PerkList=list({root,skill})}
            function a:setPerkLevelDebug(perk,n) levels[perk]=n end
            function a:getPerkLevel(perk) return levels[perk] end
            assert(I.train(a) and levels[skill]==10 and levels[root]==nil)
        ''')

    def test_hostile_state_is_exited_and_targets_are_cleared(self):
        self.lua.execute('''
            Guard=require('GoblinSurvivor/GoblinGuard')
            function a:getCurrentStateName() return 'LungeState' end
            function a:changeState(value) self.state=value end
            function a:setTarget(value) self.target=value end
            function a:setEatBodyTarget(value) self.food=value end
            ZombieIdleState={instance=function() return 'idle' end}
            a.target=player;a.food={}
            assert(Guard.apply(a) and a.state=='idle' and a.target==nil and a.food==nil)
            assert(a.variables.NoLungeAttack and not a.variables.initiateAttack)
        ''')

    def test_explicit_wait_is_not_overridden_by_idle_autonomy(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            a.data.GoblinTask='WAIT'; Autonomy.update(a,clock)
            Autonomy.update(a,clock+180000)
            assert(a.data.GoblinTask=='WAIT')
        ''')

    def test_online_idle_starts_at_30_seconds_and_motion_recalls_before_transfer(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Brain=require('GoblinSurvivor/GoblinBrain')
            player.x=0.5
            a.data.GoblinTask='FOLLOW'; Autonomy.update(a,clock)
            Autonomy.update(a,clock+29999)
            assert(a.data.GoblinTask=='FOLLOW')
            Autonomy.update(a,clock+30000)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
            player.x=10.1
            Autonomy.update(a,clock+30500)
            Brain.update(a,clock+30500)
            assert(a.data.GoblinTask=='FOLLOW' and not a.data.GoblinAutonomous)
            assert(a.destination.x==player.x and #a.inv.items==0)
            Autonomy.update(a,clock+60499)
            assert(a.data.GoblinTask=='FOLLOW')
            a.x=player.x-2
            Autonomy.update(a,clock+60500)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
        ''')

    def test_idle_autonomy_waits_until_goblin_rejoins_owner(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            a.data.GoblinTask='FOLLOW'
            a.x,a.y=player.x-12,player.y
            Autonomy.update(a,clock)
            Autonomy.update(a,clock+30000)
            assert(a.data.GoblinTask=='FOLLOW' and not a.data.GoblinAutonomous)
            a.x,a.y=player.x-2,player.y
            a.z=player.z+1
            Autonomy.update(a,clock+30250)
            assert(a.data.GoblinTask=='FOLLOW' and not a.data.GoblinAutonomous)
            a.z=player.z
            Autonomy.update(a,clock+30500)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
        ''')

    def test_idle_autonomy_accepts_a_reached_follow_slot_beyond_four_tiles(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            local Motion=require('GoblinSurvivor/GoblinLocomotion')
            player.x,player.y=10.5,0.5
            a.x,a.y=14.56,0.5
            a.data.GoblinTask='FOLLOW'
            a.data.GoblinBaseSet=false
            local target,gap,navigation=Motion.followGoal(a,player,clock)
            assert(target==nil and gap>4 and navigation.goal_key=='slot:1')
            Autonomy.update(a,clock)
            Autonomy.update(a,clock+30000)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
        ''')

    def test_manual_follow_order_gets_a_fresh_idle_window(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Brain=require('GoblinSurvivor/GoblinBrain')
            player.x=0.5
            a.data.GoblinTask='FOLLOW'; Autonomy.update(a,clock)
            Autonomy.update(a,clock+30000)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
            assert(Brain.setTask(a,'FOLLOW',{owner='horse',manual=true}))
            Autonomy.update(a,clock+31000)
            assert(a.data.GoblinTask=='FOLLOW' and not a.data.GoblinAutonomous)
            Autonomy.update(a,clock+60999)
            assert(a.data.GoblinTask=='FOLLOW')
            Autonomy.update(a,clock+61000)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
        ''')

    def test_new_companion_defaults_to_feet_and_base_can_be_set_and_cleared(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner')
            b=Spawner.ensureForPlayer(player,false)
            assert(not b.data.GoblinBaseSet and Spawner.baseForOwner('horse')==nil)
            assert(Spawner.setBaseForPlayer(player))
            assert(b.data.GoblinBaseSet and Spawner.baseForOwner('horse').x==player.x)
            assert(Spawner.setBaseForPlayer(player,true))
            assert(not b.data.GoblinBaseSet and Spawner.baseForOwner('horse')==nil)
            assert(not saved.records.horse.base_set)
        ''')

    def test_stockpile_metadata_persists_until_base_changes(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner')
            b=Spawner.ensureForPlayer(player,false)
            assert(Spawner.setBaseForPlayer(player))
            b.data.GoblinBaseReport={stale=false}
            assert(Spawner.setStockpileRuleForOwner('horse','Base.Nails',50,
                {x=10,y=0,z=0,id='real-object-id',building_id='house-a'}))
            assert(b.data.GoblinBaseReport.stale)
            local rule=Spawner.stockpileRulesForOwner('horse')['Base.Nails']
            assert(rule and rule.minimum==50 and saved.records.horse.stockpile_rules['Base.Nails'])
            assert(Spawner.setBaseForPlayer(player))
            assert(Spawner.stockpileRulesForOwner('horse')['Base.Nails'])
            player.x=11
            assert(Spawner.setBaseForPlayer(player))
            assert(not Spawner.stockpileRulesForOwner('horse')['Base.Nails'])
        ''')

    def test_feet_delivery_uses_current_owner_position_and_keeps_equipment(self):
        self.lua.execute('''
            a.data.GoblinBaseSet=false
            cargo=item('Base.Plank'); a.inv:AddItem(cargo)
            a.inv:AddItem('Base.Hammer'); a.inv:AddItem('Base.Shirt_Priest')
            assert(not Loot.deposit(a))
            player.x,player.y=1.1,0.8
            sq=cell:getGridSquare(1,0,0)
            -- No depositing into a container near the player's feet.
            chest=container();sq.objects={{getContainer=function() return chest end}}
            ok,detail,count=Loot.deposit(a)
            assert(ok and count==1 and #sq.world==1 and #chest.items==0)
            assert(sq.world[1]:getItem()==cargo and #a.inv.items==2)
            assert(cargo:getModData().GoblinDelivered)
        ''')

    def test_failed_or_blocked_delivery_keeps_cargo_without_duplication(self):
        self.lua.execute('''
            a.data.GoblinBaseSet=false;player.x,player.y=1.1,0.1
            value=item('Base.Nails');a.inv:AddItem(value)
            sq=cell:getGridSquare(1,0,0);sq.blocked=true
            assert(not Loot.deposit(a) and #a.inv.items==1 and #sq.world==0)
            sq.blocked=false;sq.rejectDrop=true
            assert(not Loot.deposit(a) and #a.inv.items==1 and #sq.world==0)
            assert(not value:getModData().GoblinDelivered)
            online=list();assert(not Loot.deposit(a) and #a.inv.items==1)
        ''')

    def test_saved_base_delivery_and_no_automatic_relooting_of_delivery(self):
        self.lua.execute('''
            cargo=item('Base.Plank');a.inv:AddItem(cargo)
            sq=cell:getGridSquare(0,0,0);chest=container()
            sq.objects={{getContainer=function() return chest end}}
            assert(Loot.deposit(a) and chest.items[1]==cargo and #a.inv.items==0)
            a.data.GoblinBaseSet=false;player.x,player.y=1.1,0.1
            ok,detail,count,done=Loot.collect(a,{autonomous=true},clock)
            assert(not done and count==0 and #chest.items==1 and a.pathCalls>0)
        ''')

    def test_base_delivery_does_not_count_duplicate_id_as_a_transfer(self):
        self.lua.execute('''
            cargo=item('Base.Plank');a.inv:AddItem(cargo)
            sq=cell:getGridSquare(0,0,0);chest=container()
            sq.objects={{getContainer=function() return chest end}}
            existing=item('Base.Plank');chest:AddItem(existing)
            -- Installed ItemContainer.AddItem returns its existing same-ID
            -- item in this case, not the incoming cargo.
            function chest:AddItem(value) return existing end
            local packets=0
            sendAddItemToContainer=function() packets=packets+1 end
            local done,detail,moved=Loot.deposit(a)
            assert(not done and moved==0 and packets==0)
            assert(#a.inv.items==1 and a.inv.items[1]==cargo)
            assert(#chest.items==1 and chest.items[1]==existing)
            assert(not cargo:getModData().GoblinDelivered)
        ''')

    def test_loot_cycle_delivers_to_feet_without_a_base(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            a.data.GoblinBaseSet=false;player.x,player.y=1.1,0.1
            sq=cell:getGridSquare(0,0,0);value=item('Base.Plank');chest=container({value})
            sq.objects={{getContainer=function() return chest end}}
            assert(Brain.setTask(a,'LOOT',{}))
            Brain.update(a,clock);Brain.update(a,clock+1500);Brain.update(a,clock+1750)
            assert(#chest.items==0 and #a.inv.items==0 and a.data.GoblinTask=='FOLLOW')
            assert(cell:getGridSquare(1,0,0).world[1]:getItem()==value)
        ''')

    def test_interrupted_idle_cargo_is_delivered_when_follow_catches_owner(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Brain=require('GoblinSurvivor/GoblinBrain')
            a.data.GoblinBaseSet=false;a.data.GoblinTask='FOLLOW'
            Autonomy.update(a,clock);Autonomy.update(a,clock+30000)
            a.inv:AddItem('Base.Plank');player.x,player.y=1.1,0.1
            Autonomy.update(a,clock+30500);Brain.update(a,clock+30500)
            assert(a.data.GoblinTask=='FOLLOW' and #a.inv.items==0)
            assert(#cell:getGridSquare(1,0,0).world==1)
        ''')

    def test_explicit_jobs_survive_movement_logout_and_rejoin(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Brain=require('GoblinSurvivor/GoblinBrain')
            a.data.GoblinTask='FOLLOW'; Autonomy.update(a,clock)
            assert(Brain.setTask(a,'LOOT',{}))
            player.x=player.x+1; Autonomy.update(a,clock+1000)
            assert(a.data.GoblinTask=='LOOT' and not a.data.GoblinAutonomous)
            online=list(); Autonomy.update(a,clock+2000)
            online=list({player}); Autonomy.update(a,clock+3000)
            assert(a.data.GoblinTask=='LOOT')
            assert(Brain.setTask(a,'WAIT',{}))
            online=list(); Autonomy.update(a,clock+4000)
            online=list({player}); Autonomy.update(a,clock+5000)
            assert(a.data.GoblinTask=='WAIT')
        ''')

    def test_offline_owner_allows_work_and_rejoin_resumes_follow(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            a.data.GoblinTask='FOLLOW'; Autonomy.update(a,clock)
            online=list(); Autonomy.update(a,clock+250)
            assert(not a.data.GoblinOwnerOnline)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
            online=list({player}); Autonomy.update(a,clock+500)
            assert(a.data.GoblinOwnerOnline and a.data.GoblinTask=='FOLLOW')
            assert(not a.data.GoblinAutonomous)
        ''')

    def test_empty_idle_search_explores_new_loaded_places_and_movement_cancels_it(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy');Brain=require('GoblinSurvivor/GoblinBrain')
            player.x,player.y=0.5,0.5;a.data.GoblinBaseSet=false;a.data.GoblinTask='FOLLOW'
            Autonomy.update(a,clock);Autonomy.update(a,clock+30000);Brain.update(a,clock+30000)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinLootStatus=='exploring for supplies')
            first=a.destination
            a.x,a.y=first.x,first.y;Brain.update(a,clock+32000)
            Brain.update(a,clock+32250)
            assert(a.destination.x~=first.x or a.destination.y~=first.y)
            assert(a.data.GoblinTaskPayload.search_cursor>1 and #a.inv.items==0)
            player.x=1;Autonomy.update(a,clock+33000);Brain.update(a,clock+33000)
            assert(a.data.GoblinTask=='FOLLOW' and not a.data.GoblinAutonomous)
            assert(Loot.jobs[a]==nil and a.destination.x==player.x)
        ''')

    def test_exploration_keeps_anchor_and_retries_blocked_or_unloaded_routes(self):
        self.lua.execute('''
            Explore=require('GoblinSurvivor/GoblinExplore')
            payload={autonomous=true};job={};anchor=Explore.anchor(a,payload)
            Explore.update(a,payload,job,clock);first=job.explore
            assert(first and Explore.within(first,anchor))
            done=Explore.update(a,payload,job,clock+20000);assert(done and job.explore==nil)
            Explore.update(a,payload,job,clock+20250)
            assert(job.explore.x~=first.x or job.explore.y~=first.y)
            a.x=999;assert(Explore.anchor(a,payload)==anchor)
            local original=cell.getGridSquare;cell.getGridSquare=function() return nil end
            job={};done,detail=Explore.update(a,payload,job,clock+21000)
            assert(not done and detail=='no loaded search route' and not job.explore)
            cell.getGridSquare=original
        ''')

    def test_idle_exploration_blacklists_stuck_waypoints_and_pauses_after_three(self):
        self.lua.execute('''
            Explore=require('GoblinSurvivor/GoblinExplore')
            local Motion=require('GoblinSurvivor/GoblinLocomotion')
            local payload={autonomous=true};local job={}
            local visited={}
            for attempt=1,3 do
                local started=clock+(attempt-1)*20100
                local done=Explore.update(a,payload,job,started)
                assert(not done and job.explore)
                local target=job.explore
                visited[#visited+1]=target
                done=Explore.update(a,payload,job,started+20000)
                assert(done and job.explore==nil)
                assert(Motion.isBlacklisted(a,target,started+20000,'target'))
            end
            assert(job.exploreFailures==3 and job.nextExploreAt==clock+120200)
            local previousCursor=payload.search_cursor
            local done,detail=Explore.update(a,payload,job,clock+60400)
            assert(not done and detail=='waiting for a loaded search route')
            assert(payload.search_cursor==previousCursor and job.explore==nil)
            done=Explore.update(a,payload,job,clock+120200)
            assert(not done and job.explore and job.exploreFailures==0)
        ''')

    def test_offline_goblin_patrols_with_cargo_without_losing_or_duplicating_it(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy');Brain=require('GoblinSurvivor/GoblinBrain')
            a.data.GoblinBaseSet=false;a.data.GoblinTask='FOLLOW';online=list()
            cargo=item('Base.CannedBeans');a.inv:AddItem(cargo)
            Autonomy.update(a,clock);Brain.update(a,clock)
            assert(a.data.GoblinTaskPayload.patrol_only and a.pathCalls==1)
            assert(a.inv.items[1]==cargo and #a.inv.items==1)
            online=list({player});Autonomy.update(a,clock+1000)
            assert(a.data.GoblinTask=='FOLLOW' and a.inv.items[1]==cargo)
        ''')

    def test_actual_player_respawn_recalls_the_same_named_goblin_but_reconnect_does_not_override_wait(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner');Brain=require('GoblinSurvivor/GoblinBrain')
            b=Spawner.ensureForPlayer(player,false);name=saved.records.horse.name
            Brain.setTask(b,'WAIT',{})
            online=list();Spawner.ensureAll(false);online=list({player});Spawner.ensureAll(false)
            assert(b.data.GoblinTask=='WAIT')
            Spawner.onPlayerDeath(player)
            function b:teleportTo(x,y,z) self.x=x;self.y=y;self.z=z;self.teleports=(self.teleports or 0)+1 end
            player.x=100;again=Spawner.ensureForPlayer(player,false)
            assert(again==b and spawnCount==1 and b.teleports==1)
            assert(saved.records.horse.name==name and b.data.GoblinTask=='FOLLOW')
            assert(b.data.GoblinTaskPayload.rejoin_run and math.abs(b.x-player.x)<10)
            Spawner.ensureForPlayer(player,false);assert(b.teleports==1)
        ''')

    def test_following_goblin_that_falls_out_of_range_is_rejoined_without_respawning(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner')
            b=Spawner.ensureForPlayer(player,false)
            assert(spawnCount==1 and b.data.GoblinTask=='FOLLOW')
            b.x,b.y=-40,0
            again=Spawner.ensureForPlayer(player,false)
            assert(again==b and spawnCount==1)
            assert(b.data.GoblinRejoinSequence==1)
            assert(b.data.GoblinRejoinPoint and math.abs(b.data.GoblinRejoinPoint.x-player.x)<10)
            assert(b.data.GoblinTaskPayload.rejoin_run==true)
            Spawner.ensureForPlayer(player,false)
            assert(b.data.GoblinRejoinSequence==1)
            b.x,b.y=b.data.GoblinRejoinPoint.x,b.data.GoblinRejoinPoint.y
            clock=clock+11000
            Spawner.ensureForPlayer(player,false)
            assert(b.data.GoblinRejoinSequence==1 and spawnCount==1)
        ''')

    def test_nearby_follower_on_adjacent_floor_uses_stairs_instead_of_rejoin_teleport(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner')
            b=Spawner.ensureForPlayer(player,false)
            b.x,b.y,b.z=4,0,0
            player.x,player.y,player.z=0,0,1
            again=Spawner.ensureForPlayer(player,false)
            assert(again==b and spawnCount==1)
            assert(b.data.GoblinRejoinSequence==nil)
            assert(b.data.GoblinRejoinPoint==nil)

            -- A discontinuous multi-floor separation still invokes the safety
            -- recall even when the planar coordinates happen to match.
            player.z=3
            Spawner.ensureForPlayer(player,false)
            assert(b.data.GoblinRejoinSequence==1)
        ''')

    def test_missing_follow_body_recreates_near_returning_owner_not_stale_checkpoint(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner');Spawner.load()
            old=Spawner.ensureForPlayer(player,false)
            old.x,old.y=100,100
            Spawner.allBodies()
            assert(saved.records.horse.position.x==100)

            -- Simulate the old cell/body being unloaded across a server
            -- lifecycle while its persistent owner record remains.
            zombies=list()
            package.loaded['GoblinSurvivor/GoblinSpawner']=nil
            Spawner=require('GoblinSurvivor/GoblinSpawner');Spawner.load()
            local replacement=Spawner.ensureForPlayer(player,false)
            assert(replacement~=old and spawnCount==2)
            assert(replacement.data.GoblinID=='goblin.primary.horse')
            assert(replacement.data.GoblinGeneration==2)
            assert(math.abs(replacement.x-player.x)<=8 and math.abs(replacement.y-player.y)<=8)

            -- If the old generation later streams back in, owner-scoped
            -- deduplication retains exactly the newer managed companion.
            zombies:add(old);Spawner.allBodies()
            assert(old.removed and Spawner.findForPlayer(player)==replacement)
        ''')

    def test_dead_owner_is_not_a_delivery_target_and_does_not_stop_offline_chores(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy');Brain=require('GoblinSurvivor/GoblinBrain')
            a.data.GoblinBaseSet=false;a.data.GoblinTask='FOLLOW'
            function player:isDead() return true end
            cargo=item('Base.CannedBeans');a.inv:AddItem(cargo)
            assert(not Loot.deliveryTarget(a))
            assert(not require('GoblinSurvivor/GoblinLocomotion').followGoal(a,player))
            Autonomy.update(a,clock);Brain.update(a,clock)
            assert(a.data.GoblinTaskPayload.patrol_only and a.pathCalls==1)
            assert(a.data.GoblinOwnerOnline==false and a.inv.items[1]==cargo)
            function player:isDead() return false end
            Autonomy.update(a,clock+1000)
            assert(a.data.GoblinTask=='FOLLOW')
        ''')

    def test_unlocked_door_and_window_use_native_entrypoints_and_window_guards_remain(self):
        self.lua.execute('''
            Access=require('GoblinSurvivor/GoblinAccess')
            object={opened=false,calls=0}
            function object:isOpen() return self.opened end
            object.IsOpen=object.isOpen
            function object:isLocked() return self.locked==true end
            function object:isBarricaded() return self.barricaded==true end
            function object:isDestroyed() return self.destroyed==true end
            function object:isLockedByKey() return self.keyLocked==true end
            function object:isPermaLocked() return self.jammed==true end
            function object:ToggleDoor(who) assert(who==a);self.opened=true;self.calls=self.calls+1 end
            object.ToggleWindow=object.ToggleDoor
            assert(Access.open(a,object,false) and object.calls==1)
            assert(not Access.open(a,object,false) and object.calls==1)
            for _,field in ipairs({'locked','barricaded','destroyed','jammed'}) do
                object.opened=false;object[field]=true
                assert(not Access.open(a,object,true) and object.calls==1)
                object[field]=nil
            end
            assert(Access.open(a,object,true) and object.calls==2)
        ''')

    def test_managed_door_access_unlocks_every_garage_segment_and_avoids_player_cast(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinAccess']=nil
            Access=require('GoblinSurvivor/GoblinAccess')
            function routeDoor(name)
                local value={name=name,opened=false,locked=true,keyLocked=true,syncs=0,silent=0,actorCalls=0,keyId=42}
                function value:isOpen() return self.opened end
                value.IsOpen=value.isOpen
                function value:isLocked() return self.locked end
                function value:setLocked(flag) self.locked=flag end
                function value:isLockedByKey() return self.keyLocked end
                function value:setLockedByKey(flag) self.keyLocked=flag end
                function value:getKeyId() return self.keyId end
                function value:isBarricaded() return false end
                function value:isDestroyed() return false end
                function value:syncIsoObject() self.syncs=self.syncs+1 end
                function value:ToggleDoorSilent() self.silent=self.silent+1;self.opened=not self.opened end
                function value:ToggleDoor() self.actorCalls=self.actorCalls+1;error('IsoPlayer cast') end
                return value
            end
            IsoDoor={}
            function IsoDoor.getDoubleDoorIndex() return -1 end
            function IsoDoor.getGarageDoorIndex(o) return o.garage and 2 or -1 end
            function IsoDoor.getGarageDoorPrev(o) return o.previous end
            function IsoDoor.getGarageDoorNext(o) return o.next end
            function IsoDoor.toggleGarageDoor(o,replicate)
                assert(replicate==true)
                local first=o;while first.previous do first=first.previous end
                while first do first.opened=true;first=first.next end
            end

            local ordinary=routeDoor('ordinary')
            assert(not Access.open(a,ordinary,false),'locked door opened without its native key')
            assert(ordinary.locked and ordinary.keyLocked and ordinary.silent==0)
            local matchingKey={}
            function a.inv:haveThisKeyId(id) assert(id==42);return matchingKey end
            assert(Access.open(a,ordinary,false))
            assert(ordinary.opened and not ordinary.locked and not ordinary.keyLocked)
            assert(ordinary.silent==1 and ordinary.actorCalls==0 and ordinary.syncs>=2)
            assert(a.data.GoblinAccessRevision==1)

            local one,two,three=routeDoor('one'),routeDoor('two'),routeDoor('three')
            one.garage,two.garage,three.garage=true,true,true
            one.next=two;two.previous=one;two.next=three;three.previous=two
            assert(Access.open(a,two,false))
            assert(a.data.GoblinAccessRevision==2)
            for _,part in ipairs({one,two,three}) do
                assert(part.opened and not part.locked and not part.keyLocked and part.syncs>=1)
                assert(part.actorCalls==0)
            end
        ''')

    def test_managed_door_access_never_unlocks_another_players_safehouse(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinAccess']=nil
            sq=cell:getGridSquare(0,0,0)
            local allowed=false
            local safehouse={playerAllowed=function(_,owner) assert(owner=='horse');return allowed end}
            SafeHouse={getSafeHouse=function(square) assert(square==sq);return safehouse end}
            IsoDoor={getDoubleDoorIndex=function() return -1 end,getGarageDoorIndex=function() return -1 end}
            local door={opened=false,locked=true,keyLocked=true,keyId=42}
            function door:getSquare() return sq end
            function door:isOpen() return self.opened end
            door.IsOpen=door.isOpen
            function door:isLocked() return self.locked end
            function door:setLocked(value) self.locked=value end
            function door:isLockedByKey() return self.keyLocked end
            function door:setLockedByKey(value) self.keyLocked=value end
            function door:getKeyId() return self.keyId end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function door:ToggleDoorSilent() self.opened=not self.opened end
            function door:syncIsoObject() end
            local matchingKey={}
            function a.inv:haveThisKeyId(id) assert(id==42);return matchingKey end
            Access=require('GoblinSurvivor/GoblinAccess')
            assert(not Access.open(a,door,false))
            assert(not door.opened and door.locked and door.keyLocked)
            allowed=true
            assert(Access.open(a,door,false))
            assert(door.opened,'door did not open')
            assert(not door.locked,'door remained locked')
            assert(not door.keyLocked,'door remained key-locked')
        ''')

    def test_key_locked_exit_can_be_unlocked_only_from_its_inside_edge(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinAccess']=nil
            Access=require('GoblinSurvivor/GoblinAccess')
            IsoFlagType={exterior={}}
            IsoDoor={getDoubleDoorIndex=function() return -1 end,
                getGarageDoorIndex=function() return -1 end}
            local inside=cell:getGridSquare(0,0,0)
            function inside:has(flag) assert(flag==IsoFlagType.exterior);return false end
            local outside=cell:getGridSquare(0,-1,0)
            function outside:has(flag) assert(flag==IsoFlagType.exterior);return true end
            local remote=cell:getGridSquare(3,3,0)
            function remote:has(flag) assert(flag==IsoFlagType.exterior);return false end
            function a:getCurrentSquare() return self.doorSide end
            function a.inv:haveThisKeyId() return nil end
            local door={opened=false,locked=true,keyLocked=true}
            function door:getSquare() return inside end
            function door:getNorth() return true end
            function door:isOpen() return self.opened end
            door.IsOpen=door.isOpen
            function door:isLocked() return self.locked end
            function door:setLocked(value) self.locked=value end
            function door:isLockedByKey() return self.keyLocked end
            function door:setLockedByKey(value) self.keyLocked=value end
            function door:getKeyId() return 42 end
            function door:isBarricaded() return false end
            function door:isDestroyed() return false end
            function door:syncIsoObject() end
            function door:ToggleDoorSilent() self.opened=not self.opened end
            a.doorSide=outside
            assert(not Access.open(a,door,false))
            a.doorSide=remote
            assert(not Access.open(a,door,false))
            assert(door.locked and door.keyLocked and not door.opened)
            a.doorSide=inside
            local lockData={CustomLock=true}
            function door:getModData() return lockData end
            assert(not Access.open(a,door,false),'inside must not bypass a native CustomLock')
            assert(door.locked and door.keyLocked and not door.opened)
            function a.inv:haveThisKeyId(id) if id==42 then return {} end end
            assert(Access.open(a,door,false),'matching key still authorizes CustomLock')
            door.opened=false;door.locked=true;door.keyLocked=true
            function a.inv:haveThisKeyId() return nil end
            lockData.CustomLock=false
            assert(Access.open(a,door,false))
            assert(door.opened and not door.locked and not door.keyLocked)
        ''')

    def test_idle_goblin_uses_delivered_base_materials_for_real_fortification(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Brain=require('GoblinSurvivor/GoblinBrain')
            player.x,player.y=0.5,0.5
            supplies(1,2);sq=cell:getGridSquare(0,0,0);chest=container()
            sq.objects={{getContainer=function() return chest end}}
            assert(Loot.deposit(a));assert(#chest.items==3 and #a.inv.items==1)
            w=window(cell:getGridSquare(1,0,0))
            a.data.GoblinTask='FOLLOW';Autonomy.update(a,clock)
            Autonomy.update(a,clock+30000)
            assert(a.data.GoblinTask=='FORTIFY' and a.data.GoblinAutonomous)
            for i=1,30 do Brain.update(a,clock+30000+i*500) end
            assert(w.barr and w.barr:getNumPlanks()==1 and #chest.items==0)
        ''')

    def test_automatic_chores_pause_for_defense_only_within_owner_leash(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            player.x,player.y=0.5,0.5
            Brain.setTask(a,'LOOT',{autonomous=true})
            enemy=actor(4,0,0);hits=0
            function enemy:Hit() hits=hits+1 end
            zombies=list({a,enemy});LosUtil={lineClear=function() return 'Clear' end}
            Brain.update(a,clock);Brain.update(a,clock+500)
            assert(hits==1 and a.data.GoblinTask=='LOOT')
            enemy.x=6;Brain.update(a,clock+1000)
            assert(hits==1 and Defense.states[a]==nil)
        ''')

    def test_loaded_offline_actor_remains_in_runtime_roster_without_respawn(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner')
            original=Spawner.ensureForPlayer(player,false)
            original.destination={x=5,y=0,z=0}
            cancels=original.cancelCalls
            online=list(); roster=Spawner.ensureAll(false)
            assert(#roster==1 and roster[1]==original and spawnCount==1)
            assert(not original.data.GoblinOwnerOnline)
            assert(original.cancelCalls==cancels and original.destination.x==5)
        ''')

    def test_follow_ignores_zombie_near_goblin_but_far_from_owner(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            a.data.GoblinTask='FOLLOW';a.data.GoblinOwnerMovingUntil=clock+500
            enemy=actor(1,0,0)
            function enemy:Hit() error('automatic attack interrupted following') end
            zombies=list({a,enemy})
            Brain.update(a,clock)
            assert(a.destination.x==player.x and a.pathCalls==1)
            assert(a.data.GoblinShotsFired==nil)
        ''')

    def test_automatic_defense_uses_five_tile_player_radius_including_boundary(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            a.data.GoblinTask='FOLLOW';player.x,player.y=1,0
            a.data.GoblinOwnerMovingUntil=clock+500
            enemy=actor(6,0,0);hits=0
            function enemy:Hit() hits=hits+1 end
            zombies=list({a,enemy})
            LosUtil={lineClear=function() return 'Clear' end}
            Brain.update(a,clock);assert(hits==0 and a.pathCalls==0)
            assert(Defense.states[a].fireAt==clock+400)
            Brain.update(a,clock+399);assert(hits==0)
            Brain.update(a,clock+500);assert(hits==1)
            -- Owner moves away; even a retained target must be dropped.
            player.x=-0.1
            Brain.update(a,clock+1000);assert(hits==1 and Defense.states[a]==nil)
        ''')

    def test_pending_shot_cancels_if_zombie_leaves_owner_radius_before_impact(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            a.data.GoblinTask='FOLLOW';player.x,player.y=0,0
            enemy=actor(4,0,0);hits=0
            function enemy:Hit() hits=hits+1 end
            zombies=list({a,enemy});LosUtil={lineClear=function() return 'Clear' end}
            Brain.update(a,clock);assert(hits==0)
            enemy.x=5.01
            Brain.update(a,clock+500);assert(hits==0 and Defense.states[a]==nil)
        ''')

    def test_automatic_defense_excludes_other_floor_and_outside_radius(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            a.data.GoblinTask='FOLLOW';player.x,player.y=1,0
            far=actor(6.01,0,0);upstairs=actor(1,0,1)
            function far:Hit() error('outside player radius') end
            function upstairs:Hit() error('wrong floor') end
            zombies=list({a,far,upstairs})
            LosUtil={lineClear=function() return 'Clear' end}
            Brain.update(a,clock);assert(a.data.GoblinShotsFired==nil)
        ''')

    def test_explicit_attack_can_pursue_outside_player_radius(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            a.data.GoblinTask='ATTACK';player.x,player.y=0,0
            enemy=actor(16,0,0);zombies=list({a,enemy})
            LosUtil={lineClear=function() return 'Clear' end}
            Brain.update(a,clock)
            assert(a.pathCalls==1 and a.destination.x==16)
        ''')

    def test_attack_command_queues_then_aims_and_applies_verified_damage(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            enemy=actor(4,0,0);enemy.health=10;hits=0;cues=0
            function enemy:getHealth() return self.health end
            function enemy:isDead() return self.health<=0 end
            function enemy:Hit(weapon,who) assert(who==a);hits=hits+1;self.health=self.health-8;return 8 end
            zombies=list({a,enemy});LosUtil={lineClear=function() return 'Clear' end}
            sendServerCommand=function(module,command) if command=='combat' then cues=cues+1 end end
            ok,detail=Brain.setTask(a,'ATTACK',{})
            assert(ok and hits==0 and cues==0 and not detail:find('fired'))
            Brain.update(a,clock);assert(hits==0 and cues==1)
            Brain.update(a,clock+399);assert(hits==0)
            Brain.update(a,clock+400);assert(hits==1 and enemy.health==2 and a.data.GoblinShotsFired==1)
        ''')

    def test_explicit_blocked_attack_paths_without_firing_and_reaims_when_clear(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            enemy=actor(4,0,0);hits=0;clear=false
            function enemy:Hit() hits=hits+1 end
            zombies=list({a,enemy});LosUtil={lineClear=function() return clear and 'Clear' or 'Blocked' end}
            assert(Brain.setTask(a,'ATTACK',{}));Brain.update(a,clock)
            assert(a.data.GoblinTask=='ATTACK' and a.pathCalls==1 and hits==0)
            Brain.update(a,clock+1000);assert(a.data.GoblinTask=='ATTACK' and hits==0)
            clear=true;Brain.update(a,clock+1500);assert(hits==0)
            Brain.update(a,clock+1900);assert(hits==1)
        ''')

    def test_unreachable_attack_reports_failure_instead_of_area_clear(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            enemy=actor(4,0,0);function enemy:Hit() error('must not shoot through wall') end
            zombies=list({a,enemy});LosUtil={lineClear=function() return 'Blocked' end}
            Brain.setTask(a,'ATTACK',{});Brain.update(a,clock)
            ok,detail=Brain.update(a,clock+45000)
            assert(not ok and detail:find('could not reach') and a.data.GoblinTask=='FOLLOW')
            assert(a.speech:find('could not reach') and not a.speech:find('area clear'))
        ''')

    def test_attack_does_not_count_no_damage_native_hit_as_success(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            enemy=actor(4,0,0);function enemy:getHealth() return 1 end
            function enemy:Hit() return 0 end
            zombies=list({a,enemy});LosUtil={lineClear=function() return 'Clear' end}
            Brain.setTask(a,'ATTACK',{});Brain.update(a,clock)
            ok,detail=Brain.update(a,clock+400)
            assert(not ok and detail:find('did not damage') and a.data.GoblinShotsFired==nil)
            assert(a.data.GoblinTask=='FOLLOW' and a.speech:find('did not damage'))
        ''')

    def test_new_order_cancels_old_shot_and_dead_targets_are_not_selected(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            enemy=actor(4,0,0);hits=0;enemy.health=1
            function enemy:getHealth() return self.health end
            function enemy:Hit() hits=hits+1 end
            zombies=list({a,enemy});LosUtil={lineClear=function() return 'Clear' end}
            Brain.setTask(a,'ATTACK',{});Brain.update(a,clock)
            Brain.setTask(a,'WAIT',{});Brain.update(a,clock+500);assert(hits==0)
            enemy.health=0;Brain.setTask(a,'ATTACK',{});Brain.update(a,clock+1000)
            assert(hits==0 and a.data.GoblinTask=='FOLLOW')
        ''')

    def test_automatic_defense_does_not_chase_an_escaping_target(self):
        self.lua.execute('''
            Brain=require('GoblinSurvivor/GoblinBrain')
            Defense=require('GoblinSurvivor/GoblinDefense');Defense.install()
            a.data.GoblinTask='FOLLOW'; player.x,player.y=0.5,0.5
            a.x,a.y=3.4,0.5 -- Already at the new stand-off; no back-away path is needed.
            enemy=actor(20,0,0)
            Defense.states[a]={target=enemy,nextAttackAt=0}
            LosUtil={lineClear=function() return 'Clear' end}
            Brain.update(a,clock)
            assert(a.pathCalls==0 and a.data.GoblinTask=='FOLLOW')
        ''')

    def test_offline_grant_is_single_use_and_cannot_override_rejoin_or_explicit_order(self):
        self.lua.execute('''
            Authority=require('GoblinSurvivor/Authority')
            online=list();a.data.GoblinTask='FOLLOW';a.data.GoblinTaskSequence=1
            a.data.GoblinGeneration=1
            token=Authority.issueOffline(a);assert(token)
            msg={action='LOOT_AREA',owner='horse',npc_id=a.data.GoblinID,authority_token=token}
            assert(Authority.consumeOffline(msg,a));assert(not Authority.consumeOffline(msg,a))
            msg.authority_token=Authority.issueOffline(a)
            online=list({player});assert(not Authority.consumeOffline(msg,a))
            online=list();a.data.GoblinTask='WAIT';a.data.GoblinTaskSequence=2
            assert(not Authority.consumeOffline(msg,a));assert(not Authority.issueOffline(a))
            a.data.GoblinTask='FOLLOW';msg.authority_token=Authority.issueOffline(a)
            msg.owner='someone_else';assert(not Authority.consumeOffline(msg,a))
            msg.owner='horse';msg.action='BUILD';assert(not Authority.consumeOffline(msg,a))
            msg.action='LOOT_AREA';clock=clock+120001
            assert(not Authority.consumeOffline(msg,a))
        ''')

    def test_persistent_roster_includes_unloaded_offline_goblin_with_saved_name(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner')
            original=Spawner.ensureForPlayer(player,false)
            name=saved.records.horse.name
            original.removed=true;online=list()
            roster=Spawner.snapshotAll()
            assert(#roster==1 and roster[1].name==name and roster[1].persisted)
            assert(not roster[1].body_present and not roster[1].owner_online)
            assert(spawnCount==1)
        ''')
