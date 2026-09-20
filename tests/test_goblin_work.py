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
            a.engineOwner={}
            function a:getOwnerPlayer() return nativePlayer end
            local clientOwned=realBody.snapshot(a)
            assert(clientOwned.navigation.simulation_owner=='client')
            assert(clientOwned.navigation.native_owner_player=='unicorn')
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

    def test_items_cannot_be_taken_through_walls_or_above_capacity(self):
        self.lua.execute('''
            sq=cell:getGridSquare(1,0,0); sq.blocked=true
            value=item('Base.Plank'); inv=container({value})
            assert(not World.take(a,{square=sq,container=inv,item=value}))
            sq.blocked=false; a.inv.full=true
            assert(not World.take(a,{square=sq,container=inv,item=value}))
            assert(#inv.items==1)
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
            a.data.GoblinTask='FOLLOW'; Autonomy.update(a,clock)
            Autonomy.update(a,clock+29999)
            assert(a.data.GoblinTask=='FOLLOW')
            Autonomy.update(a,clock+30000)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
            player.x=player.x+0.1
            Autonomy.update(a,clock+30500)
            Brain.update(a,clock+30500)
            assert(a.data.GoblinTask=='FOLLOW' and not a.data.GoblinAutonomous)
            assert(a.destination.x==player.x and #a.inv.items==0)
            Autonomy.update(a,clock+60499)
            assert(a.data.GoblinTask=='FOLLOW')
            Autonomy.update(a,clock+60500)
            assert(a.data.GoblinTask=='LOOT' and a.data.GoblinAutonomous)
        ''')

    def test_manual_follow_order_gets_a_fresh_idle_window(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Brain=require('GoblinSurvivor/GoblinBrain')
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
