"""Execute production Lua in Lua 5.1 with small engine boundary doubles."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime
from goblin_zomboid.protocol import PROTOCOL_VERSION, decode_message, make_message

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'mod/Contents/mods/GoblinSurvivor/42/media/lua'


class GoblinLuaTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        paths = ';'.join((LUA / scope / '?.lua').as_posix() for scope in ('shared', 'server', 'client'))
        self.lua.globals().test_paths = paths
        self.lua.execute('package.path = test_paths .. ";" .. package.path')
        self.lua.execute((ROOT / 'tests/lua/goblin_fixture.lua').read_text())
        self.lua.execute('Config=require("GoblinSurvivor/Config"); Motion=require("GoblinSurvivor/GoblinLocomotion")')

    def test_all_packaged_lua_parses_as_51(self):
        for path in LUA.rglob('*.lua'):
            self.lua.globals().source = path.read_text(encoding='utf-8-sig')
            self.lua.execute('assert(loadstring(source))')

    def test_client_trace_is_opt_in_and_samples_only_identified_goblins(self):
        source = LUA / 'client/GoblinSurvivor/GoblinClientTrace.lua'
        self.lua.globals().trace_source = source.read_text(encoding='utf-8')
        self.lua.execute('''
            clientMode=true; getPlayer=function() return player end
            clock=1790190000000
            messages={}; print=function(line) messages[#messages+1]=line end
            getFileReader=function() return nil end
            local disabled=assert(loadstring(trace_source))()
            assert(type(disabled.sampleBody)=='function')
            disabled.sampleBody(actor(0,0,0),nil);assert(#messages==0)

            local closed=false
            getFileReader=function(path,create)
                assert(path=='goblin-m1-trace.flag' and create==false)
                return {readLine=function() return 'enabled' end,
                    close=function() closed=true end}
            end
            local trace=assert(loadstring(trace_source))()
            assert(not closed and type(trace.sampleBody)=='function')
            player.running=true;player.sprinting=false
            function player:isRunning() return self.running end
            function player:isSprinting() return self.sprinting end
            local a=actor(4.25,5.5,0);a.data.GoblinNPC=true
            a.data.GoblinID='dev.survivor.001.horse'
            local b=actor(7,5,0);b.id=6
            function b:getOutfitName() return Config.npcOutfit end
            local ordinary=actor(8,8,0)
            trace.sampleBody(a,{npc_id=a.data.GoblinID})
            trace.sampleBody(b,nil)
            trace.sampleBody(ordinary,nil)
            assert(closed and #messages==3)
            assert(string.find(messages[1],'M1_CLIENT_TRACE_READY',1,true))
            assert(string.find(messages[2],'remote=false',1,true))
            assert(string.find(messages[2],'prun=true psprint=false',1,true))
            assert(string.find(messages[2],'id=dev.survivor.001.horse',1,true))
            assert(string.find(messages[3],'id=online.6',1,true))
            clock=clock+50;trace.sampleBody(a,{npc_id=a.data.GoblinID});assert(#messages==3)
            clock=clock+50;a.x=4.5;a.remote=true
            player.running=false;player.sprinting=true
            trace.sampleBody(a,{npc_id=a.data.GoblinID});trace.sampleBody(b,nil)
            assert(#messages==5 and string.find(messages[4],'remote=true',1,true))
            assert(string.find(messages[4],'x=4.5000',1,true))
            assert(string.find(messages[4],'prun=false psprint=true',1,true))
        ''')

    def test_real_lua_ipc_and_python_share_the_wire_protocol(self):
        self.assertEqual(self.lua.eval('Config.protocol'), PROTOCOL_VERSION)
        self.lua.execute('''
            IPC=require('GoblinSurvivor/IPC');IPC.initialized=true;IPC.root='goblin-bridge'
            written={}
            goblinServerWriteFile=function(path,text) written[path]=text;return true end
            assert(IPC.publishRuntime('zomboid-state',{
                protocol=Config.protocol,request_id='live-lua-state',timestamp_ms=10000,
                type='runtime.state',companion_count=1,body_present=true
            }))
            assert(IPC.publish('events',{
                protocol=Config.protocol,request_id='live-lua-chat',timestamp_ms=10000,
                type='event.chat',speaker='horse',text='Goblin, are you here?'
            }))
            assert(written['goblin-bridge/events/live-lua-chat.ready']=='1')
        ''')
        for file in ('runtime/zomboid-state.json', 'events/live-lua-chat.json'):
            message=decode_message(self.lua.globals().written['goblin-bridge/'+file].encode())
            self.assertEqual(message.protocol,PROTOCOL_VERSION)
        import json
        self.lua.globals().python_wire=json.dumps(make_message('command.intent',intent='SAY').as_dict())
        self.lua.execute('''
            function getFileReader(path)
                local read=false
                return {readLine=function() if read then return nil end;read=true;return python_wire end,
                    close=function() end}
            end
            local message=IPC.readReady('commands','python-command')
            assert(message and message.protocol==Config.protocol and message.intent=='SAY')
        ''')

    def test_inventory_restore_fails_closed_and_save_only_follows_restore(self):
        self.lua.execute('''
            Persistence=require('GoblinSurvivor/GoblinPersistence');a=actor(0,0,0)
            writes=0
            goblinServerInventorySave=function() writes=writes+1;return 'saved' end
            goblinServerInventoryRestore=function() return 'disabled' end
            assert(not Persistence.restore(a,'goblin.primary.horse'))
            assert(not Persistence.save(a,true) and writes==0)
            goblinServerInventoryRestore=function() return 'error:IOException' end
            assert(not Persistence.restore(a,'goblin.primary.horse'))
            assert(not Persistence.save(a,true) and writes==0)
            goblinServerInventoryRestore=function() return 'restored:7' end
            assert(Persistence.restore(a,'goblin.primary.horse'))
            assert(Persistence.save(a,true) and writes==1 and a.data.GoblinInventoryPersistent)
            assert(Persistence.save(a,false) and writes==1)
            clock=clock+2001
            assert(Persistence.save(a,false) and writes==2)
            goblinServerInventorySave=nil
            assert(not Persistence.available())
        ''')

    def test_follow_stops_at_three_tiles_and_resumes_when_owner_moves(self):
        self.lua.execute('''
            a=actor(6,0,0)
            goal,gap=Motion.followGoal(a,player)
            assert(goal and gap == 4)
            Motion.drive(a,goal,'WALK',clock)
            assert(a.pathCalls == 1)
            a.x=7.1
            goal,gap=Motion.followGoal(a,player)
            assert(goal == nil and gap < 3 and gap > 2.5)
            Motion.drive(a,goal,'IDLE',clock)
            assert(a.useless and a.cancelCalls == 1)
            assert(a.variables.bMoving == false)
            assert(a.variables.GoblinMoveType == 'IDLE')
            player.x=15
            clock=clock+2000
            goal=Motion.followGoal(a,player)
            Motion.drive(a,goal,'WALK',clock)
            assert(a.pathCalls == 2 and a.destination.x == 15)
        ''')

    def test_remote_peers_do_not_path_or_cancel_and_authority_handoff_repaths(self):
        self.lua.execute('''
            a=actor(0,0,0); goal={x=10,y=0,z=0}; a.engineOwner={}
            Motion.drive(a,goal,'WALK',clock); Motion.stop(a)
            assert(a.pathCalls == 0 and a.cancelCalls == 0)
            clientMode=true; a.remote=true
            Motion.drive(a,goal,'WALK',clock); Motion.stop(a)
            assert(a.pathCalls == 0 and a.cancelCalls == 0)
            a.remote=false
            Motion.drive(a,goal,'WALK',clock)
            assert(a.pathCalls == 1)
            a.remote=true; Motion.drive(a,goal,'WALK',clock)
            a.remote=false; Motion.drive(a,goal,'WALK',clock)
            assert(a.pathCalls == 2)
        ''')

    HOUSE = '''
        -- House interior x 5..9, y 0..4. West wall has a closed window at y=2;
        -- the south wall has a doorway at x=7 (doorOpen toggles it).
        doorOpen=true
        local function inside(x,y) return x>=5 and x<=9 and y>=0 and y<=4 end
        local cache={}
        function cell:getGridSquare(x,y,z)
            local k=x..':'..y..':'..z
            if cache[k] then return cache[k] end
            local s={x=x,y=y,z=z}
            function s:getX() return self.x end
            function s:getY() return self.y end
            function s:getZ() return self.z end
            function s:isFree() return true end
            function s:getMovingObjects() return list() end
            function s:haveFire() return false end
            function s:getRoom() if inside(self.x,self.y) then return {} end end
            local function crossing(a,b)
                return inside(a.x,a.y)~=inside(b.x,b.y)
            end
            local function isDoorEdge(a,b)
                return crossing(a,b) and a.x==7 and b.x==7 and ((a.y==4 and b.y==5) or (a.y==5 and b.y==4))
            end
            local function isWindowEdge(a,b)
                return crossing(a,b) and a.y==2 and b.y==2 and ((a.x==4 and b.x==5) or (a.x==5 and b.x==4))
            end
            function s:isDoorTo(o) return isDoorEdge(self,o) end
            function s:getDoorTo(o) if isDoorEdge(self,o) then return {isBarricaded=function() return false end} end end
            function s:isWindowTo(o) return isWindowEdge(self,o) end
            function s:isBlockedTo(o)
                if isDoorEdge(self,o) then return not doorOpen end
                return crossing(self,o)
            end
            cache[k]=s
            return s
        end
    '''

    def test_route_enters_a_house_by_its_door_not_the_window(self):
        # Live: Goblins stood at a closed window outside the owner's house
        # (IsoZombie paths assume windows can be smashed) while doors were open.
        self.lua.execute(self.HOUSE)
        self.lua.execute('''
            local route=assert(Motion.planRoute({x=2.5,y=2.5,z=0},{x=7.5,y=2.5,z=0}))
            local seen=false
            for i,p in ipairs(route) do
                if math.floor(p.x)==7 and math.floor(p.y)==4 then seen=true end
                assert(not (math.floor(p.x)==5 and math.floor(p.y)==2 and i==1), 'went through the window')
            end
            assert(seen, 'route did not use the door')
            doorOpen=false  -- a closed door is still a way in (the server opens it)
            local closed=assert(Motion.planRoute({x=2.5,y=2.5,z=0},{x=7.5,y=2.5,z=0}))
            assert(#closed==#route)
        ''')

    def test_route_waypoints_never_cut_through_the_window(self):
        self.lua.execute(self.HOUSE)
        self.lua.execute('''
            a=actor(2.5,2.5,0)
            local goal={x=7.5,y=2.5,z=0}
            for i=1,40 do
                local waypoint,options=Motion.routeWaypoint(a,goal,{},clock+i*100)
                if waypoint==goal then break end
                assert(options.goal_type=='route')
                -- One hop never crosses the wall except through the doorway.
                local ax,ay=math.floor(a.x),math.floor(a.y)
                local wx,wy=math.floor(waypoint.x),math.floor(waypoint.y)
                local inA=ax>=5 and ax<=9 and ay>=0 and ay<=4
                local inW=wx>=5 and wx<=9 and wy>=0 and wy<=4
                if inA~=inW then assert(wx==7 and (wy==4 or wy==5) and ax==7, 'hop crossed a wall') end
                a.x,a.y=waypoint.x,waypoint.y
            end
            assert(math.floor(a.x)>=5 and math.floor(a.x)<=9, 'never got inside')
        ''')

    def test_jittering_goal_does_not_restart_the_route_every_frame(self):
        # Live: ~150 native re-requests in 15 s while Goblin stood still,
        # because a goal re-rounded across a tile edge reset the route.
        self.lua.execute('''
            a=actor(0,0,0)
            local lines={}
            print=function(line) lines[#lines+1]=line end
            for i=0,40 do
                local goal={x=10+(i%2)*1.1,y=0.5,z=0}
                Motion.drive(a,goal,'WALK',clock+i*100)
            end
            assert(a.pathCalls<=4, 'route restarted '..a.pathCalls..' times in 4 s')
            -- A real move (new target several tiles away) still paths at once.
            local before=a.pathCalls
            Motion.drive(a,{x=20,y=5,z=0},'WALK',clock+4100)
            assert(a.pathCalls==before+1)
        ''')

    def test_stationary_actor_is_retried_without_restart_every_frame(self):
        self.lua.execute('''
            a=actor(0,0,0); goal={x=10,y=0,z=0}
            for i=0,50 do Motion.drive(a,goal,'WALK',clock+i*100) end
            assert(a.pathCalls == 1)
            Motion.drive(a,goal,'WALK',clock+6100)
            assert(a.pathCalls == 1 and a.behaviorCalls == 1
                and a.nativeState == 'PathFindState' and Motion.paths[a].failures == 1)
        ''')

    def test_managed_destination_suppresses_native_idle_wander_only_on_controller(self):
        self.lua.execute('''
            a=actor(0,0,0); goal={x=10,y=0,z=0}; delays={}
            function a:getCurrentStateName() return self.nativeState end
            function a:setStateEventDelayTimer(value) delays[#delays+1]=value end
            a.nativeState='ZombieIdleState'
            for i=0,5 do Motion.drive(a,goal,'WALK',clock+i*100) end
            assert(#delays==6 and delays[1]==1000 and delays[6]==1000)
            assert(a.pathCalls==1,'refreshing the idle timer must not repath')
            a.nativeState='WalkTowardState'
            Motion.drive(a,goal,'WALK',clock+700)
            assert(#delays==6,'other native states retain their own timers')
            Motion.drive(a,nil,'IDLE',clock+800)
            assert(#delays==6,'idle without a managed destination is untouched')
            clientMode=true; a.remote=true; a.nativeState='ZombieIdleState'
            Motion.drive(a,goal,'WALK',clock+900)
            assert(#delays==6,'remote peers never alter the simulator timer')
        ''')

    def test_native_route_leaves_zombie_idle_on_simulation_owner(self):
        self.lua.execute('''
            WalkTowardState={instance=function() return 'native-walk' end}
            PathFindState={instance=function() return 'native-pathfind' end}
            a=actor(0,0,0);a.nativeState='ZombieIdleState'
            function a:getCurrentStateName() return self.nativeState end
            function a:getVariableBoolean(key) return self.variables[key]==true end
            function a:changeState(value) self.entered=value;self.nativeState=value end
            local original=a.pathToLocationF
            function a:pathToLocationF(x,y,z)
                original(self,x,y,z);self.variables.bPathfind=false
            end
            Motion.drive(a,{x=10,y=0,z=0},'WALK',clock)
            assert(a.entered=='native-walk' and a.pathCalls==1)
            a.nativeState='ZombieIdleState';a.entered=nil
            a.x=1
            a.variables.bPathfind=true
            function a:pathToLocationF(x,y,z)
                original(self,x,y,z);self.variables.bPathfind=true
            end
            Motion.drive(a,{x=20,y=0,z=0},'WALK',clock+100)
            assert(a.entered=='native-pathfind' and a.pathCalls==2)
            clientMode=true;a.remote=true;a.nativeState='ZombieIdleState';a.entered=nil
            Motion.drive(a,{x=25,y=0,z=0},'WALK',clock+200)
            assert(a.entered==nil and a.pathCalls==2)
        ''')

    def test_stalled_managed_route_uses_native_behavior_beyond_void_wrapper(self):
        self.lua.execute('''
            PathFindState={instance=function() return 'PathFindState' end}
            a=actor(0,0,0);a.nativeState='WalkTowardState'
            function a:getCurrentStateName() return self.nativeState end
            function a:changeState(state) self.nativeState=state end
            function a:pathToLocationF(x,y,z)
                -- IsoZombie returns void without submitting while throttled.
                if self.allowRepathDelay>0 then return end
                self.pathCalls=self.pathCalls+1
            end
            local behavior={cancel=function() end,
                pathToLocationF=function(self,x,y,z)
                    self.calls=(self.calls or 0)+1;self.goal={x=x,y=y,z=z}
                end}
            function a:getPathFindBehavior2() return behavior end
            a.allowRepathDelay=3
            Motion.drive(a,{x=10,y=0,z=0},'WALK',clock)
            assert(a.pathCalls==0 and not behavior.calls)
            Motion.drive(a,{x=10,y=0,z=0},'WALK',clock+6100)
            assert(behavior.calls==1 and behavior.goal.x==10)
            assert(a.nativeState=='PathFindState' and a.variables.bPathfind==true)
            clientMode=true;a.remote=true
            Motion.drive(a,{x=20,y=0,z=0},'WALK',clock+6200)
            assert(behavior.calls==1,'remote peer must not request native path')
        ''')

    def test_native_idle_or_face_interrupt_recovers_managed_route_before_stuck_timeout(self):
        self.lua.execute('''
            a=actor(0,0,0);goal={x=10,y=0,z=0}
            Motion.drive(a,goal,'WALK',clock)
            assert(a.pathCalls==1 and a.behaviorCalls==0)
            a.nativeState='ZombieFaceTargetState'
            Motion.drive(a,goal,'WALK',clock+500)
            assert(a.behaviorCalls==0,'respect the native repath cooldown')
            Motion.drive(a,goal,'WALK',clock+1300)
            assert(a.behaviorCalls==1 and a.nativeState=='PathFindState')
            assert(Motion.paths[a].failures==1,'state interruption consumes the bounded recovery')
            a.nativeState='ZombieIdleState'
            Motion.drive(a,goal,'WALK',clock+1400)
            assert(a.behaviorCalls==1,'do not retry every frame')
            Motion.drive(a,goal,'WALK',clock+2600)
            assert(a.behaviorCalls==1,'do not reissue a stationary interrupted route')
            local ok,reason=Motion.drive(a,goal,'WALK',clock+7400)
            assert(not ok and reason=='no progress after native repath')
            clientMode=true;a.remote=true;a.nativeState='ZombieFaceTargetState'
            Motion.drive(a,goal,'WALK',clock+4000)
            assert(a.behaviorCalls==1,'only the simulator may recover the route')
        ''')

    def test_stalled_pathfind_state_exits_before_replacement_request(self):
        self.lua.execute('''
            a=actor(0,0,0);a.nativeState='PathFindState'
            local transitions={}
            function a:changeState(state)
                transitions[#transitions+1]=state;self.nativeState=state
            end
            local submit=a.pathBehavior.pathToLocationF
            a.pathBehavior.pathToLocationF=function(self,x,y,z)
                assert(a.nativeState=='ZombieIdleState',
                    'native PathFindState.exit must run before replacing its request')
                submit(self,x,y,z)
            end
            local goal={x=10,y=0,z=0}
            Motion.drive(a,goal,'WALK',clock)
            Motion.drive(a,goal,'WALK',clock+6100)
            assert(transitions[1]=='ZombieIdleState' and transitions[2]=='PathFindState')
            assert(a.behaviorCalls==1 and a.nativeState=='PathFindState')
        ''')

    def test_opened_access_revision_forces_immediate_native_repath(self):
        self.lua.execute('''
            a=actor(0,0,0); goal={x=10,y=0,z=0}
            Motion.drive(a,goal,'WALK',clock)
            assert(a.pathCalls==1)
            clock=clock+100
            Motion.drive(a,goal,'WALK',clock,{obstruction_cleared=true})
            assert(a.pathCalls==2,'door-open signal did not bypass the normal repath cooldown')
        ''')

    def test_nearby_move_to_uses_walk_instead_of_idle(self):
        self.lua.execute('''
            a=actor(0,0,0); a.data={GoblinNPC=true,GoblinOwner='horse'}
            Movement=require('GoblinSurvivor/GoblinMovement')
            assert(Movement.command(a,'MOVE_TO',{x=2,y=0,z=0}))
            assert(a.data.GoblinMoveType == 'WALK' and a.pathCalls == 1)
        ''')

    def test_invalid_movement_coordinates_and_radius_never_reach_native_pathing(self):
        self.lua.execute('''
            a=actor(0,0,0);a.data={GoblinNPC=true,GoblinOwner='horse'}
            Movement=require('GoblinSurvivor/GoblinMovement')
            for _,payload in ipairs({
                {x=0/0,y=1,z=0}, {x=math.huge,y=1,z=0},
                {x=2,y=1,z=0,radius=math.huge},
                {x=2,y=1,z=0,radius=-1}
            }) do
                local ok,detail=Movement.command(a,'MOVE_TO',payload)
                assert(not ok and detail=='target unavailable')
                assert(a.pathCalls==0 and a.data.GoblinMovementGoal==nil)
            end
            local ok,detail=Motion.drive(a,{x=math.huge,y=0,z=0},'RUN',clock)
            assert(not ok and detail=='invalid destination' and a.pathCalls==0)
            a.x=math.huge
            assert(Motion.position(a)==nil)
            assert(Motion.distance({x=0,y=0,z=0},{x=0/0,y=0,z=0})==math.huge)
        ''')

    def test_invalid_actor_position_waits_without_access_or_path_side_effects(self):
        self.lua.execute('''
            a=actor(math.huge,0,0);a.data={GoblinNPC=true,GoblinOwner='horse'}
            Movement=require('GoblinSurvivor/GoblinMovement')
            local Access=require('GoblinSurvivor/GoblinAccess')
            local original=Access.update
            Access.update=function() error('access ran with invalid actor position') end
            local accepted,detail=Movement.command(a,'MOVE_TO',{x=4,y=0,z=0})
            assert(accepted and detail=='movement queued; waiting for Goblin position')
            assert(Movement.snapshot(a).task=='MOVE_TO' and a.pathCalls==0)
            assert(a.data.GoblinMovementGoal==nil and a.data.GoblinMoveType=='IDLE')
            Access.update=original
            a.x=0
            Movement.update(a,clock+250)
            assert(a.pathCalls==1 and a.data.GoblinMovementGoal.x==4)
        ''')

    def test_visuals_wait_for_asset_then_add_once_and_repair_replication_overwrite(self):
        self.lua.execute('''
            Appearance=require('GoblinSurvivor/GoblinAppearance'); a=actor(0,0,0)
            assetReady=false
            assert(not Appearance.apply(a,clock)); assert(a.visuals:size() == 0)
            assetReady=true; clock=clock+2000
            assert(Appearance.apply(a,clock)); assert(a.visuals:size() == 5)
            assert(a.visuals:get(4):getItemType() == Config.npcVisualItemType)
            for i,kind in ipairs(Config.npcOutfitItems) do
                assert(a.visuals:get(i-1):getItemType()==kind)
            end
            assert(a.human.skin==Config.npcSkinTexture and a.human.hair=='' and a.human.beard=='')
            clock=clock+2000
            assert(Appearance.apply(a,clock)); assert(a.visuals:size() == 5 and a.resets == 1)
            a.visuals:clear(); clock=clock+2000
            assert(Appearance.apply(a,clock)); assert(a.visuals:size() == 5 and a.resets == 2)
            -- Remove replicated duplicates without touching inventory.
            for _,kind in ipairs(Config.npcOutfitItems) do
                local v=ItemVisual.new();v:setItemType(kind);a.visuals:add(v)
            end
            clock=clock+2000
            assert(Appearance.apply(a,clock) and a.visuals:size()==5 and a.resets==3)
            assert(a.inventory[1]=='kept-item')
            a.human.skin='M_ZedBody01';clock=clock+2000
            assert(Appearance.apply(a,clock) and a.human.skin==Config.npcSkinTexture and a.resets==4)
            assert((listBoundsErrors or 0)==0)
        ''')

    def test_long_follow_uses_native_character_target_and_keeps_one_stable_slot_nearby(self):
        self.lua.execute('''
            Movement=require('GoblinSurvivor/GoblinMovement')
            a=actor(0,0,0);a.data={GoblinNPC=true,GoblinOwner='horse'}
            Movement.command(a,'FOLLOW',{})
            assert(a.characterPathCalls==1 and a.pathTarget==player)
            a.x=6;player.x=10
            local first,gap,context=Motion.followGoal(a,player,clock)
            local slot=Motion.followSlots[a]
            assert(first and context.goal_type=='follow_slot' and slot)
            player.x=10.2
            local second=Motion.followGoal(a,player,clock+100)
            assert(second and Motion.followSlots[a]==slot)
        ''')

    def test_clear_follow_route_accepts_half_tile_position_jitter(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0);player.x,player.y=3.75,0.5
            local goal,gap,navigation=Motion.followGoal(a,player,clock)
            assert(not goal and gap>3 and navigation.goal_key=='arrived')
            local original=cell.getGridSquare
            function cell:getGridSquare(x,y,z)
                local square=original(self,x,y,z)
                function square:isBlockedTo(other)
                    return (self:getX()==1 and other:getX()==2)
                        or (self:getX()==2 and other:getX()==1)
                end
                return square
            end
            goal,gap,navigation=Motion.followGoal(a,player,clock+100)
            assert(goal and navigation.goal_key~='arrived',
                'an obstacle must not be hidden by the arrival margin')
        ''')

    def test_stalled_character_follow_repath_uses_current_coordinate_fallback(self):
        self.lua.execute('''
            a=actor(0,0,0);player.x=12
            local goal,gap,context=Motion.followGoal(a,player,clock)
            assert(Motion.drive(a,goal,'RUN',clock,context))
            assert(a.characterPathCalls==1 and a.pathCalls==1)
            player.x=13
            goal,gap,context=Motion.followGoal(a,player,clock+6100)
            assert(Motion.drive(a,goal,'RUN',clock+6100,context))
            assert(a.characterPathCalls==1 and a.pathCalls==1 and a.behaviorCalls==1)
            assert(Motion.paths[a].route=='location-repath')
            assert(a.destination.x==13)
        ''')

    def test_blocked_follow_routes_use_bounded_open_edge_detour(self):
        self.lua.execute('''
            clientMode=true
            a=actor(0,0,0);player.x=10;player.y=0
            local squares={}
            function cell:getGridSquare(x,y,z)
                if math.abs(x)>12 or math.abs(y)>12 or z~=0 then return nil end
                local key=x..':'..y
                if not squares[key] then
                    local square={x=x,y=y}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return 0 end
                    function square:isFree() return true end
                    function square:haveFire() return false end
                    function square:getMovingObjects() return list() end
                    function square:isBlockedTo(other)
                        return self.y==0 and other.y==0
                            and ((self.x==0 and other.x==1)
                                or (self.x==1 and other.x==0))
                    end
                    squares[key]=square
                end
                return squares[key]
            end
            local goal,gap,context=Motion.followGoal(a,player,clock)
            assert(context.goal_type=='character')
            assert(Motion.drive(a,goal,'RUN',clock,context))
            goal,gap,context=Motion.followGoal(a,player,clock+6100)
            assert(Motion.drive(a,goal,'RUN',clock+6100,context))
            goal,gap,context=Motion.followGoal(a,player,clock+12100)
            local ok,reason=Motion.drive(a,goal,'RUN',clock+12100,context)
            assert(not ok and reason=='no progress after native repath')
            local detour,_,navigation=Motion.followGoal(a,player,clock+12101)
            assert(detour and detour.x==0.5 and math.abs(detour.y)==0.5)
            assert(navigation.goal_type=='follow_detour')
            assert(Motion.drive(a,detour,'RUN',clock+12101,navigation))
            assert(a.destination.x==detour.x and a.destination.y==detour.y)
            assert(a.x==0 and a.y==0,'detour must not position-write')
            Motion.stop(a)
            assert(Motion.followDetours[a]==nil)
            player.x=2
            a.data.GoblinPathState='blocked'
            a.data.GoblinNavigationGoalType='follow_slot'
            local slotDetour,_,slotNavigation=Motion.followGoal(a,player,clock+12102)
            assert(slotDetour and slotDetour.x==0.5 and math.abs(slotDetour.y)==0.5)
            assert(slotNavigation.goal_type=='follow_detour')
            Motion.stop(a)
            player.x=10
            for _,square in pairs(squares) do
                function square:isBlockedTo(other) return true end
            end
            local sealed,_,sealedNavigation=Motion.followGoal(a,player,clock+12102)
            assert(sealed and sealed.x==player.x and sealedNavigation.goal_type=='character')
            assert(a.x==0 and a.y==0,'a sealed route must not teleport')
        ''')

    def test_work_detour_routes_around_wall_and_requires_exact_destination(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0)
            local goal={x=3.5,y=0.5,z=0}
            local sealed=false
            function cell:getGridSquare(x,y,z)
                if x<0 or x>3 or y<0 or y>1 or z~=0 then return nil end
                local square={x=x,y=y}
                function square:getX() return self.x end
                function square:getY() return self.y end
                function square:getZ() return 0 end
                function square:isFree() return true end
                function square:haveFire() return false end
                function square:getMovingObjects() return list() end
                function square:isBlockedTo(other)
                    if sealed then return true end
                    return self.y==0 and other.y==0 and self.x~=other.x
                end
                return square
            end
            Motion.blacklist(a,goal,'blocked wall',clock)
            assert(Motion.drive(a,goal,'WALK',clock))
            assert(a.destination.x==0.5 and a.destination.y==1.5)
            assert(Motion.paths[a].goalType=='work_detour')
            a.x,a.y=0.5,1.5;clock=clock+500
            assert(Motion.drive(a,goal,'WALK',clock))
            assert(a.destination.x==1.5 and a.destination.y==1.5)
            Motion.stop(a);sealed=true
            local calls=a.pathCalls
            assert(not Motion.drive(a,goal,'WALK',clock+1))
            assert(a.pathCalls==calls,'sealed route must not submit a through-wall path')
            assert(a.x==0.5 and a.y==1.5,'recovery must not teleport')
            sealed=false;Motion.stop(a)
            goal={x=3,y=0,z=0}
            Motion.blacklist(a,goal,'blocked wall',clock)
            assert(Motion.drive(a,goal,'WALK',clock+2))
            assert(Motion.paths[a].goalType=='work_detour',
                'non-centred destinations still need a route to their tile')
            a.x,a.y=3.5,0.5
            assert(Motion.drive(a,goal,'WALK',clock+1000))
            assert(a.destination.x==3 and a.destination.y==0,
                'final work coordinate must not be replaced with tile centre')
        ''')

    def test_follow_detour_can_enter_a_square_from_an_alternate_edge(self):
        self.lua.execute('''
            a=actor(0,0,0);player.x=4;player.y=0
            a.data.GoblinPathState='blocked'
            a.data.GoblinNavigationGoalType='character'
            local open={}
            local function allow(x1,y1,x2,y2)
                open[x1..':'..y1..'|'..x2..':'..y2]=true
                open[x2..':'..y2..'|'..x1..':'..y1]=true
            end
            allow(0,0,0,1);allow(0,1,1,1);allow(1,1,1,0)
            allow(1,0,2,0);allow(2,0,3,0);allow(3,0,4,0)
            local squares={}
            function cell:getGridSquare(x,y,z)
                if x<0 or x>4 or y<0 or y>1 or z~=0 then return nil end
                local key=x..':'..y
                if not squares[key] then
                    local square={x=x,y=y}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return 0 end
                    function square:isFree() return true end
                    function square:haveFire() return false end
                    function square:getMovingObjects() return list() end
                    function square:isBlockedTo(other)
                        return not open[self.x..':'..self.y..'|'..other.x..':'..other.y]
                    end
                    squares[key]=square
                end
                return squares[key]
            end
            local waypoint,_,navigation=Motion.followGoal(a,player,clock)
            assert(waypoint and waypoint.x==0.5 and waypoint.y==1.5)
            assert(navigation.goal_type=='follow_detour')
        ''')

    def test_blocked_follow_detour_can_go_around_a_long_fence(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0);player.x,player.y=0.5,4.5
            a.data.GoblinPathState='blocked'
            a.data.GoblinNavigationGoalType='character'
            local squares={}
            function cell:getGridSquare(x,y,z)
                if math.abs(x)>23 or y < -2 or y > 7 or z~=0 then return nil end
                local key=x..':'..y
                if not squares[key] then
                    local square={x=x,y=y}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return 0 end
                    function square:isFree() return true end
                    function square:haveFire() return false end
                    function square:getMovingObjects() return list() end
                    function square:isBlockedTo(other)
                        return ((self.y==1 and other.y==2)
                            or (self.y==2 and other.y==1))
                            and math.abs(self.x)<=14
                    end
                    squares[key]=square
                end
                return squares[key]
            end
            local waypoint,_,navigation=Motion.followGoal(a,player,clock)
            assert(waypoint and navigation.goal_type=='follow_detour',
                'navigation='..tostring(navigation and navigation.goal_type))
            assert(waypoint.x==0.5 and waypoint.y==1.5,
                'waypoint='..tostring(waypoint.x)..','..tostring(waypoint.y))
            assert(a.x==0.5 and a.y==0.5,'detour must not position-write')
        ''')

    def test_blocked_follow_detour_still_runs_after_a_long_idle_patrol(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0);player.x,player.y=20.5,0.5
            a.data.GoblinPathState='blocked'
            a.data.GoblinNavigationGoalType='character'
            local squares={}
            function cell:getGridSquare(x,y,z)
                if x<0 or x>21 or math.abs(y)>2 or z~=0 then return nil end
                local key=x..':'..y
                if not squares[key] then
                    local square={x=x,y=y}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return 0 end
                    function square:isFree() return true end
                    function square:haveFire() return false end
                    function square:getMovingObjects() return list() end
                    function square:isBlockedTo() return false end
                    squares[key]=square
                end
                return squares[key]
            end
            local waypoint,_,navigation=Motion.followGoal(a,player,clock)
            assert(waypoint and navigation.goal_type=='follow_detour')
            assert(waypoint.x==1.5 and waypoint.y==0.5)
        ''')

    def test_blocked_follow_detour_reaches_diagonal_leader_within_search_budget(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0);player.x,player.y=11.5,11.5
            a.data.GoblinPathState='blocked'
            a.data.GoblinNavigationGoalType='character'
            local squares={}
            function cell:getGridSquare(x,y,z)
                if x<0 or x>12 or y<0 or y>12 or z~=0 then return nil end
                local key=x..':'..y
                if not squares[key] then
                    local square={x=x,y=y}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return 0 end
                    function square:isFree() return true end
                    function square:haveFire() return false end
                    function square:getMovingObjects() return list() end
                    function square:isBlockedTo() return false end
                    squares[key]=square
                end
                return squares[key]
            end
            local waypoint,_,navigation=Motion.followGoal(a,player,clock)
            assert(waypoint and navigation.goal_type=='follow_detour')
            assert((waypoint.x==1.5 and waypoint.y==0.5)
                or (waypoint.x==0.5 and waypoint.y==1.5))
            assert(a.x==0.5 and a.y==0.5,'detour must not position-write')
        ''')

    def test_follow_detour_can_use_only_exit_blacklisted_as_full_target(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0);player.x,player.y=0.5,4.5
            a.data.GoblinPathState='blocked'
            a.data.GoblinNavigationGoalType='follow_slot'
            local squares={}
            function cell:getGridSquare(x,y,z)
                if x~=0 or y<0 or y>4 or z~=0 then return nil end
                local key=x..':'..y
                if not squares[key] then
                    local square={x=x,y=y}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return 0 end
                    function square:isFree() return true end
                    function square:haveFire() return false end
                    function square:getMovingObjects() return list() end
                    function square:isBlockedTo() return false end
                    squares[key]=square
                end
                return squares[key]
            end
            Motion.blacklist(a,{x=0.5,y=1.5,z=0},'failed slot',clock,'target')
            local waypoint,_,navigation=Motion.followGoal(a,player,clock+1)
            assert(waypoint and waypoint.x==0.5 and waypoint.y==1.5)
            assert(navigation.goal_type=='follow_detour')
            assert(navigation.blacklist_kind=='approach')
            assert(Motion.drive(a,waypoint,'RUN',clock+1,navigation))
            assert(a.destination.x==0.5 and a.destination.y==1.5)
            assert(a.x==0.5 and a.y==0.5,'detour must not position-write')
        ''')

    def test_follow_slot_rejects_occupied_preference_and_selects_an_alternate(self):
        self.lua.execute('''
            a=actor(6,0,0);player.x=10
            local original=cell.getGridSquare
            function cell:getGridSquare(x,y,z)
                local square=original(self,x,y,z)
                function square:isFree() return x~=6 end
                return square
            end
            local goal,gap,context=Motion.followGoal(a,player,clock)
            assert(goal and context.goal_type=='follow_slot')
            assert(Motion.followSlots[a]~=5 and math.floor(goal.x)~=6)
        ''')

    def test_follow_slot_cannot_finish_on_opposite_side_of_closed_door_or_wall(self):
        self.lua.execute('''
            local squares={}
            function cell:getGridSquare(x,y,z)
                local key=x..':'..y..':'..z
                if not squares[key] then
                    local square={x=x,y=y,z=z}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return self.z end
                    function square:isFree() return self.x==0 and self.y==4 end
                    function square:getMovingObjects() return list() end
                    function square:haveFire() return false end
                    function square:isBlockedTo(other)
                        return self.x==0 and other.x==0
                            and ((self.y==1 and other.y==2) or (self.y==2 and other.y==1))
                    end
                    squares[key]=square
                end
                return squares[key]
            end
            a=actor(0.5,4.5,0);player.x,player.y=0.5,0.5
            local goal,gap,context=Motion.followGoal(a,player,clock)
            assert(goal and goal.x==player.x and goal.y==player.y)
            assert(context.goal_type=='character' and context.goal_key=='character-fallback')
            assert(Motion.followSlots[a]==nil)

            -- Being inside the configured preferred distance is not arrival
            -- when the actor and owner are still separated by a blocked edge.
            squares={};a.x,a.y=0.5,2.5
            goal,gap,context=Motion.followGoal(a,player,clock+100)
            assert(gap<=3 and goal and goal.x==player.x and goal.y==player.y)
            assert(context.goal_type=='character' and context.goal_key=='character-fallback')
        ''')

    def test_follow_slot_rejects_diagonal_corner_with_no_cardinal_route(self):
        self.lua.execute('''
            local squares={}
            local openSide=false
            function cell:getGridSquare(x,y,z)
                local key=x..':'..y..':'..z
                if not squares[key] then
                    local square={x=x,y=y,z=z}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return self.z end
                    function square:isFree() return self.x==3 and self.y==3 end
                    function square:getMovingObjects() return list() end
                    function square:haveFire() return false end
                    function square:isBlockedTo(other)
                        if self.x==3 and self.y==3
                            and ((other.x==2 and other.y==3) or (other.x==3 and other.y==2)) then
                            return not openSide
                        end
                        return false
                    end
                    squares[key]=square
                end
                return squares[key]
            end
            a=actor(3.5,3.5,0);player.x,player.y=0.5,0.5
            local goal,gap,context=Motion.followGoal(a,player,clock)
            assert(goal and context.goal_type=='character' and Motion.followSlots[a]==nil)
            openSide=true
            goal,gap,context=Motion.followGoal(a,player,clock+100)
            assert(goal==nil) -- already standing in the now-reachable slot
            assert(context.goal_type=='follow_slot' and Motion.followSlots[a]==2)
        ''')

    def test_follow_does_not_claim_arrival_when_edge_check_is_unavailable(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0);player.x,player.y=3.1,0.5
            for _,failure in ipairs({'missing','throws','nil'}) do
                function cell:getGridSquare(x,y,z)
                    local square={x=x,y=y,z=z}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return self.z end
                    function square:isFree() return true end
                    function square:getMovingObjects() return list() end
                    function square:haveFire() return false end
                    if failure=='throws' then
                        function square:isBlockedTo() error('edge unavailable') end
                    elseif failure=='nil' then
                        function square:isBlockedTo() return nil end
                    end
                    return square
                end
                local goal,gap,context=Motion.followGoal(a,player,clock)
                assert(gap<=3 and goal and goal.x==player.x and goal.y==player.y)
                assert(context.goal_type=='character' and context.goal_key=='character-fallback')
                assert(Motion.followSlots[a]==nil)
            end
        ''')

    def test_follow_slot_requires_readable_occupants_and_fire_state(self):
        self.lua.execute('''
            a=actor(0.5,0.5,0);player.x,player.y=2.5,0.5
            for _,failure in ipairs({'missing-occupants','bad-list','missing-fire','throws-fire'}) do
                function cell:getGridSquare(x,y,z)
                    local square={x=x,y=y,z=z}
                    function square:getX() return self.x end
                    function square:getY() return self.y end
                    function square:getZ() return self.z end
                    function square:isFree() return true end
                    function square:isBlockedTo() return false end
                    if failure~='missing-occupants' then
                        function square:getMovingObjects()
                            if failure=='bad-list' then return {size=function() return 'unknown' end} end
                            return list()
                        end
                    end
                    if failure=='throws-fire' then
                        function square:haveFire() error('fire check unavailable') end
                    elseif failure~='missing-fire' then
                        function square:haveFire() return false end
                    end
                    return square
                end
                local goal,gap,context=Motion.followGoal(a,player,clock)
                assert(gap<2.5 and goal==nil)
                assert(context.goal_type=='follow_slot' and context.goal_key=='clearance-unavailable')
                assert(Motion.followSlots[a]==nil)
            end
        ''')

    def test_stuck_recovery_repaths_once_blacklists_then_expires_without_looping(self):
        self.lua.execute('''
            a=actor(0,0,0);goal={x=10,y=0,z=0}
            assert(Motion.drive(a,goal,'WALK',clock))
            assert(Motion.drive(a,goal,'WALK',clock+6100))
            assert(a.pathCalls==1 and a.behaviorCalls==1)
            local ok,detail=Motion.drive(a,goal,'WALK',clock+12200)
            assert(not ok and detail=='no progress after native repath'
                and a.pathCalls==1 and a.behaviorCalls==1)
            assert(a.cancelCalls==1 and a.variables.bPathfind==false
                and a.variables.bMoving==false,
                'abandoned path must not keep native pathfinding active')
            -- With no loaded alternate route, retries must remain bounded.
            squareUnavailable=true
            for i=1,20 do Motion.drive(a,goal,'WALK',clock+12200+i*100) end
            assert(a.pathCalls==1 and a.behaviorCalls==1 and Motion.isBlacklisted(a,goal,clock+15000))
            squareUnavailable=false
            local alternate={x=10,y=1,z=0}
            assert(Motion.drive(a,alternate,'WALK',clock+16000))
            assert(a.pathCalls==2 and a.destination.y==1,
                'a different approach must start a fresh native path')
            assert(Motion.drive(a,goal,'WALK',clock+43000) and a.pathCalls==3)
            local snapshot=Motion.snapshot(a,clock+43000)
            assert(snapshot.path_state=='pathing' and snapshot.simulation_owner=='server')
        ''')

    def test_blocked_navigation_logs_diagnostic_once_and_keeps_last_movement(self):
        self.lua.execute('''
            a=actor(0,0,0)
            local messages={}
            print=function(line) messages[#messages+1]=line end
            local goal={x=10,y=0,z=0}
            local options={current_task='MOVE_TO'}
            assert(Motion.drive(a,goal,'WALK',clock,options))
            a.x=1
            assert(Motion.drive(a,goal,'WALK',clock+100,options))
            local last=a.data.GoblinLastSuccessfulMovementAt
            local unsafePathReads=0
            function a:getPath2()
                return setmetatable({}, {__index=function()
                    unsafePathReads=unsafePathReads+1
                    error('native Path methods are not Lua exposed')
                end})
            end
            function a:pathToLocationF(x,y,z) return false end
            local other={x=12,y=0,z=0}
            local ok,reason=Motion.drive(a,other,'WALK',clock+200,options)
            assert(not ok and reason=='native path rejected')
            local snapshot=Motion.snapshot(a,clock+200)
            assert(snapshot.current_task=='MOVE_TO' and snapshot.path_state=='blocked')
            assert(snapshot.last_successful_movement_at==last)
            assert(#messages==1)
            assert(string.find(messages[1],'NAV_BLOCKED',1,true))
            assert(string.find(messages[1],'task=MOVE_TO',1,true))
            assert(string.find(messages[1],'reason=native path rejected',1,true))
            assert(unsafePathReads==0,'blocked diagnostic must not index native Path methods')
            Motion.drive(a,other,'WALK',clock+300,options)
            local blockedLogs=0
            for _,message in ipairs(messages) do
                if string.find(message,'NAV_BLOCKED',1,true) then blockedLogs=blockedLogs+1 end
            end
            assert(blockedLogs==1,'a detour attempt must not duplicate the blocked diagnostic')
            assert(Motion.snapshot(a,clock+300).blocked_reason=='native path rejected')
        ''')

    def test_spawn_outfit_uses_lua_exposed_character_accessor_not_raw_outfit_object(self):
        self.lua.execute('''
            Appearance=require('GoblinSurvivor/GoblinAppearance');a=actor(0,0,0)
            unsafeReads=0
            function a:getHumanVisual() unsafeReads=unsafeReads+1;error('Outfit is not exposed to Lua') end
            function a:getOutfitName() return self.outfit end
            assert(not Appearance.isSpawnOutfit(a)) -- creation before outfit arrives
            a.outfit='Survivor';assert(not Appearance.isSpawnOutfit(a))
            a.outfit='GoblinCompanion';assert(Appearance.isSpawnOutfit(a))
            assert(unsafeReads==0)
        ''')

    def test_human_guard_never_writes_read_only_native_animation_callbacks(self):
        self.lua.execute('''
            Guard=require('GoblinSurvivor/GoblinGuard');a=actor(0,0,0)
            readOnlyWrites=0
            local write=a.setVariable
            function a:setVariable(key,value)
                local k=string.lower(key)
                if k=='blunge' or k=='alerted' or k=='issitting' then
                    readOnlyWrites=readOnlyWrites+1
                end
                write(self,key,value)
            end
            for i=1,5 do Guard.apply(a) end
            assert(readOnlyWrites==0 and a.variables.GoblinNPC==true)
            assert(a.variables.NoLungeAttack and a.variables.NoLungeTarget)
        ''')

    def test_idle_animation_guard_does_not_freeze_an_active_native_route(self):
        self.lua.execute('''
            Guard=require('GoblinSurvivor/GoblinGuard');a=actor(0,0,0)
            function a:getCurrentStateName() return 'IdleState' end
            function a:getVariableBoolean(key) return self.variables[key] == true end
            a.useless=false
            Motion.paths[a]={goalKey='character',goalType='character'}
            Guard.apply(a)
            assert(a.useless==false)
            Motion.paths[a]=nil
            Guard.apply(a)
            assert(a.useless==true)
        ''')

    def test_turnalerted_human_fallback_can_finish_the_native_transition(self):
        import xml.etree.ElementTree as ET
        node = ET.parse(ROOT / 'mod/Contents/mods/GoblinSurvivor/common/media/AnimSets/'
                        'zombie/turnalerted/goblinHumanFallback.xml').getroot()
        self.assertEqual(node.findtext('m_Looped'), 'false')
        self.assertEqual(node.findtext('m_StopAnimOnExit'), 'true')
        self.assertEqual(node.findtext('m_AnimName'), 'Bob_IdleRifle')
        self.assertEqual(node.findtext('m_Conditions/m_Name'), 'GoblinNPC')
        self.assertEqual(node.findtext('m_Conditions/m_Value'), 'true')
        guard = (LUA / 'shared/GoblinSurvivor/GoblinGuard.lua').read_text()
        self.assertNotIn('getActionContext', guard)  # not Lua-exposed in installed B42

    def test_follow_mirrors_owner_running_and_sprinting_without_waiting_for_a_large_gap(self):
        self.lua.execute('''
            Movement=require('GoblinSurvivor/GoblinMovement')
            a=actor(6.5,0,0);a.data={GoblinNPC=true,GoblinOwner='horse'}
            function player:isRunning() return self.running==true end
            function player:isSprinting() return self.sprinting==true end
            player.running=true
            Movement.command(a,'FOLLOW',{})
            assert(a.data.GoblinMoveType=='RUN' and a.running==false)
            player.running=false;player.sprinting=true
            Movement.update(a,clock+250);assert(a.data.GoblinMoveType=='RUN')
            player.sprinting=false
            Movement.update(a,clock+500);assert(a.data.GoblinMoveType=='WALK')
            a.x=7.1;Movement.update(a,clock+750)
            assert(a.data.GoblinMoveType=='IDLE')
            assert(Movement.snapshot(a).task=='FOLLOW')
            player.x=20
            Movement.update(a,clock+1000)
            assert(a.data.GoblinMoveType=='RUN' and a.pathCalls>=2)
            assert(Motion.moveType(nil,1,player)=='IDLE')
        ''')

    def test_follow_waits_for_streamed_squares_without_forgetting_its_task(self):
        self.lua.execute('''
            Movement=require('GoblinSurvivor/GoblinMovement')
            a=actor(8.5,0,0);a.data={GoblinNPC=true,GoblinOwner='horse'}
            squareUnavailable=true
            local accepted,detail=Movement.command(a,'FOLLOW',{})
            assert(accepted and detail=='follow queued; waiting for owner or world data')
            local ok,reason=Movement.update(a,clock+100)
            assert(not ok and reason=='follow position unavailable')
            assert(Movement.snapshot(a).task=='FOLLOW' and a.pathCalls==0)
            squareUnavailable=false
            player.x=20
            Movement.update(a,clock+250)
            assert(a.pathCalls==1 and Movement.snapshot(a).task=='FOLLOW')
        ''')

    def test_follow_waits_for_offline_owner_and_resumes_on_rejoin(self):
        self.lua.execute('''
            Movement=require('GoblinSurvivor/GoblinMovement')
            a=actor(0,0,0);a.data={GoblinNPC=true,GoblinOwner='horse'}
            online=list({})
            local accepted,detail=Movement.command(a,'FOLLOW',{})
            assert(accepted and detail=='follow queued; waiting for owner or world data')
            assert(Movement.snapshot(a).task=='FOLLOW' and a.pathCalls==0)
            online=list({player})
            Movement.update(a,clock+250)
            assert(a.pathCalls==1 and Movement.snapshot(a).task=='FOLLOW')
        ''')

    def test_map_draws_only_the_local_owners_marker_and_labels_stale_positions(self):
        self.lua.execute('''
            Map=require('GoblinSurvivor/GoblinMap')
            assert(Map.receive({owner='horse',npc_id='goblin.primary.horse',name='Ratspit',x=4,y=5,body_present=true},clock))
            assert(Map.receive({owner='unicorn',npc_id='goblin.primary.unicorn',name='Sootfang',x=8,y=9,body_present=true},clock))
            UIFont={Small='small'}
            getTextManager=function() return {MeasureStringX=function(_,font,text) return #text*5 end} end
            getSpecificPlayer=function() return player end
            panel={labels={},rects=0,mapAPI={worldToUIX=function(_,x,y) return x*10 end,
                worldToUIY=function(_,x,y) return y*10 end}}
            function panel:getWidth() return 400 end
            function panel:getHeight() return 300 end
            function panel:drawRect(x,y) self.rects=self.rects+1;assert(x<50) end
            function panel:drawText(text) self.labels[#self.labels+1]=text end
            Map.draw(panel,clock);assert(panel.labels[1]=='Ratspit' and panel.rects==2)
            Map.draw(panel,clock+10001);assert(panel.labels[2]=='Ratspit (last known)')
            assert(not Map.receive({owner='horse',npc_id='g',name='Bad',x=0/0,y=0},clock))
        ''')

    def test_respawn_teleport_is_one_shot_only_on_the_native_simulator(self):
        self.lua.execute('''
            a=actor(0,0,0);calls=0
            function a:teleportTo(x,y,z) calls=calls+1;self.x=x;self.y=y;self.z=z end
            point={x=20,y=30,z=0}
            a.engineOwner={};assert(not Motion.rejoin(a,point,1,clock+1000,clock))
            clientMode=true;a.remote=true;assert(not Motion.rejoin(a,point,1,clock+1000,clock))
            a.remote=false;assert(Motion.rejoin(a,point,1,clock+1000,clock) and calls==1)
            assert(not Motion.rejoin(a,point,1,clock+1000,clock) and calls==1)
            assert(not Motion.rejoin(a,point,2,clock-1,clock))
            squareUnavailable=true;assert(not Motion.rejoin(a,point,2,clock+1000,clock))
        ''')

    def test_rejoin_does_not_consume_sequence_when_native_teleport_is_ignored(self):
        self.lua.execute('''
            a=actor(0,0,0);clientMode=true;a.remote=false
            point={x=20,y=30,z=0};attempts=0
            function a:teleportTo(x,y,z) attempts=attempts+1 end
            assert(not Motion.rejoin(a,point,1,clock+1000,clock))
            function a:teleportTo(x,y,z)
                attempts=attempts+1;self.x=x;self.y=y;self.z=z
            end
            assert(Motion.rejoin(a,point,1,clock+1000,clock))
            assert(attempts==2 and a.x==20 and a.y==30)
        ''')

    def test_server_native_rejoin_releases_remote_simulation_authority(self):
        self.lua.execute('''
            a=actor(0,0,0);a.engineOwner={};calls=0
            function a:teleportTo(x,y,z) calls=calls+1;self.x=x;self.y=y;self.z=z end
            goblinServerRejoin=function(body,x,y,z)
                assert(body==a and isServer() and a.engineOwner)
                a.engineOwner=nil
                body:teleportTo(x,y,z)
                return true
            end
            point={x=120,y=130,z=0}
            assert(Motion.rejoin(a,point,1,clock+1000,clock))
            assert(calls==1 and a.x==120 and a.y==130)
            assert(not Motion.rejoin(a,point,1,clock+1000,clock) and calls==1)
            clientMode=true;a.remote=true;a.engineOwner={}
            assert(not Motion.rejoin(a,point,2,clock+1000,clock) and calls==1)
            clientMode=false;goblinServerRejoin=nil
            assert(not Motion.rejoin(a,point,2,clock+1000,clock) and calls==1)
        ''')

    def test_native_walk_entry_is_enabled_only_for_requested_path(self):
        self.lua.execute('''
            a=actor(0,0,0);a.useless=true
            local original=a.pathToLocationF
            function a:pathToLocationF(x,y,z)
                assert(self.useless==false,'native WalkTowardState would reject this path')
                original(self,x,y,z)
            end
            Motion.drive(a,{x=10,y=0,z=0},'WALK',clock)
            assert(a.pathCalls==1 and not a.useless)
            Motion.stop(a);assert(a.useless)
            Guard=require('GoblinSurvivor/GoblinGuard')
            function a:getCurrentStateName() return 'ZombieIdleState' end
            function a:getVariableBoolean(k) return self.variables[k]==true end
            a.useless=false;Guard.apply(a);assert(a.useless)
            a.useless=false;a.variables.bMoving=true;Guard.apply(a);assert(not a.useless)
        ''')

    def test_goblin_voice_is_private_silent_and_repaired_after_native_descriptor_changes(self):
        self.lua.execute('''
            Audio=require('GoblinSurvivor/GoblinAudio');copies=0;stops={}
            function desc(prefix)
                return {prefix=prefix,getVoicePrefix=function(self) return self.prefix end,
                    setVoicePrefix=function(self,v) self.prefix=v end}
            end
            SurvivorDesc={new=function(old) copies=copies+1;return desc(old.prefix) end}
            a=actor(0,0,0);other=actor(1,0,0);shared=desc('MaleZombie')
            a.desc=shared;other.desc=shared
            function a:getDescriptor() return self.desc end
            function a:setDescriptor(value) self.desc=value end
            function other:getDescriptor() return self.desc end
            function a:getEmitter() return {
                stopSoundByName=function(_,name) stops[name]=true end,
                stopAll=function() error('must preserve weapons and footsteps') end
            } end
            function a:setHurtSound(value) self.hurt=value end
            function a:setDoDeathSound(value) self.deathSound=value end
            assert(not Audio.silence(a) and copies==0) -- ordinary actor is untouched
            a.data.GoblinNPC=true
            assert(Audio.silence(a) and copies==1 and a.desc~=shared)
            assert(a.desc.prefix=='GoblinCompanion' and other.desc.prefix=='MaleZombie')
            assert(a.hurt=='GoblinCompanionVoiceA' and a.deathSound==false)
            assert(stops.MaleZombieVoiceA and stops.MaleZombieSprinterVoiceC and stops.MaleZombieBiteB)
            assert(not stops.PistolShot and not stops.Footsteps)
            assert(Audio.silence(a) and copies==1)
            a.desc.prefix='FemaleZombie' -- native gender/replication overwrite
            assert(Audio.silence(a) and copies==1 and a.desc.prefix==Audio.prefix)
            assert(stops.FemaleZombieVoiceA)
            a.desc=desc('MaleZombie') -- native descriptor replacement
            assert(Audio.silence(a) and copies==2 and a.desc.prefix==Audio.prefix)
            assert(other.desc.prefix=='MaleZombie')
        ''')

    def test_run_uses_native_speed_type_without_player_only_fence_vault(self):
        self.lua.execute('''
            a=actor(0,0,0)
            function a:setWalkType(v) self.walkType=v end
            function a:setSpeedTypeFromWalkType() self.speedType=self.walkType=='sprint' and 1 or 2 end
            Motion.drive(a,{x=20,y=0,z=0},'RUN',clock)
            assert(a.running==false and a.speedType==1 and a.variables.GoblinMoveType=='RUN')
        ''')

    def test_combat_cue_shows_weapon_aim_then_recoil_without_inventory_mutation(self):
        self.lua.execute('''
            Visual=require('GoblinSurvivor/GoblinCombatVisual');a=actor(0,0,0)
            sounds=0;created=0
            instanceItem=function(kind) created=created+1;return {getFullType=function() return kind end} end
            function a:getPrimaryHandItem() return self.hand end
            function a:setPrimaryHandItem(item) self.hand=item end
            function a:setSecondaryHandItem(item) self.secondary=item end
            function a:getEmitter() return {playSound=function() sounds=sounds+1 end} end
            state={npc_id='goblin.primary.horse',generation=1,action=''}
            cue={npc_id=state.npc_id,generation=1,sequence=1,x=3,y=0}
            assert(Visual.cue(cue,clock));assert(not Visual.cue(cue,clock))
            assert(Visual.apply(a,state,clock)=='AIM' and sounds==0)
            assert(a.hand and a.hand==a.secondary and created==1)
            assert(Visual.apply(a,state,clock+400)=='SHOOT' and sounds==1)
            Visual.apply(a,state,clock+500);assert(sounds==1 and created==1)
            assert(Visual.apply(a,state,clock+900)=='')
            assert(a.inventory[1]=='kept-item' and #a.inventory==1)
        ''')

    def test_goblin_equip_does_not_enter_player_only_fishing_and_players_are_unchanged(self):
        self.lua.execute('''
            Compat=require('GoblinSurvivor/GoblinPlayerEvents');calls=0
            Fishing={Handler={handleFishing=function(who,item)
                calls=calls+1;assert(who==player and item=='rod');return 'original-result'
            end}}
            a=actor(0,0,0);a.data.GoblinNPC=true
            assert(Compat.install());local wrapper=Fishing.Handler.handleFishing
            assert(Compat.install() and Fishing.Handler.handleFishing==wrapper)
            Fishing.Handler.handleFishing(a,'shotgun');assert(calls==0)
            assert(Fishing.Handler.handleFishing(player,'rod')=='original-result' and calls==1)
        ''')

    def test_nameplate_uses_saved_name_and_hides_occluded_dead_or_unloaded_bodies(self):
        self.lua.execute('''
            Names=require('GoblinSurvivor/GoblinNameplates');a=actor(10,0,0)
            visible=true;dead=false;draws={}
            function a:getSquare() return {isCanSee=function() return visible end} end
            function a:isDead() return dead end
            function a:getAlpha() return 1 end
            function a:getScreenX() return 300 end
            function a:getScreenY() return 400 end
            Core={getTileScale=function() return 2 end};UIFont={Small='small'}
            IsoCamera={getOffX=function() return 100 end,getOffY=function() return 100 end,
                getScreenLeft=function() return 0 end,getScreenTop=function() return 0 end,
                getScreenWidth=function() return 800 end,getScreenHeight=function() return 600 end}
            getCore=function() return {getZoom=function() return 1 end} end
            getTextManager=function() return {
                getFontHeight=function() return 12 end,MeasureStringX=function() return 100 end,
                DrawStringCentre=function(self,font,x,y,name) draws[#draws+1]={x=x,y=y,name=name} end
            } end
            getNumActivePlayers=function() return 1 end
            getSpecificPlayer=function() return player end
            state={npc_id='goblin.primary.horse',name='Ratspit Ashlicker',body_present=true}
            states={[state.npc_id]=state}
            Names.track(a,state,clock);Names.render(states,clock)
            assert(#draws==2 and draws[2].name==state.name and draws[2].x==200 and draws[2].y==160)
            visible=false;Names.render(states,clock);assert(#draws==2)
            visible=true;dead=true;Names.render(states,clock);assert(#draws==2)
            dead=false;Names.render(states,clock+2001);assert(#draws==2)
        ''')

    def test_companion_opacity_only_for_owner_ready_loaded_same_floor_actor(self):
        self.lua.execute('''
            V=require('GoblinSurvivor/GoblinVisibility');a=actor(0,0,0)
            a.alpha=0;a.render=true;a.square={};a.dead=false
            function a:getSquare() return self.square end
            function a:isDead() return self.dead end
            function a:getDoRender() return self.render end
            function a:setAlphaAndTarget(index,value) assert(index==0);self.alpha=value;self.target=value end
            getNumActivePlayers=function() return 2 end
            getSpecificPlayer=function(index) if index==0 then return player end;return {getUsername=function() return 'unicorn' end} end
            state={npc_id='goblin.primary.horse',owner='horse',body_present=true}
            V.track(a,state,true,clock);V.update(clock)
            assert(a.alpha==1 and a.target==1)
            a.alpha=0;V.update(clock+1);assert(a.alpha==1)
            for _,field in ipairs({'dead','render','square','z'}) do
                local old=a[field];a.alpha=0
                if field=='dead' then a[field]=true elseif field=='render' then a[field]=false
                elseif field=='square' then a[field]=nil else a[field]=1 end
                V.update(clock+2);assert(a.alpha==0);a[field]=old
            end
            a.alpha=0;V.track(a,state,false,clock);V.update(clock);assert(a.alpha==0)
            V.track(a,state,true,clock);V.update(clock+2001);assert(a.alpha==0)
            assert(not V.owned({},player))
            state.owner='unicorn';assert(not V.apply(a,state,player,0))
            state.owner='horse';state.body_present=false;assert(not V.apply(a,state,player,0))
        ''')

    def test_owner_name_remains_visible_outside_field_of_view(self):
        self.lua.execute('''
            Names=require('GoblinSurvivor/GoblinNameplates');a=actor(10,0,0);draws=0
            function a:getSquare() return {isCanSee=function() return false end} end
            function a:isDead() return false end
            function a:getAlpha() return 1 end
            function a:getScreenX() return 300 end
            function a:getScreenY() return 400 end
            Core={getTileScale=function() return 2 end};UIFont={Small='small'}
            IsoCamera={getOffX=function() return 100 end,getOffY=function() return 100 end,
                getScreenLeft=function() return 0 end,getScreenTop=function() return 0 end,
                getScreenWidth=function() return 800 end,getScreenHeight=function() return 600 end}
            getCore=function() return {getZoom=function() return 1 end} end
            getTextManager=function() return {getFontHeight=function() return 12 end,
                MeasureStringX=function() return 100 end,DrawStringCentre=function() draws=draws+1 end} end
            state={npc_id='goblin.primary.horse',owner='horse',name='Ratspit Ashlicker',body_present=true}
            Names.draw(a,state,player,0);assert(draws==2)
            state.owner='unicorn';Names.draw(a,state,player,0);assert(draws==2)
        ''')

    def test_speech_queues_until_chat_is_ready_and_displays_as_goblin_without_relay(self):
        self.lua.execute('''
            Speech=require('GoblinSurvivor/GoblinSpeech')
            assert(not Speech.show('Ratspit Ashlicker','Comrade, supplies are here.'))
            ChatManager=nil; displayed={}
            ChatMessage={new=function(chat,text)
                local m={text=text,chat=chat}
                function m:setAuthor(v) self.author=v end
                function m:setText(v) self.text=v end
                function m:isShowAuthor() return false end
                for _,k in ipairs({'setShowInChat','setOverHeadSpeech','setShouldAttractZombies','setLocal'}) do
                    m[k]=function() end
                end
                return m
            end}
            native={getChat=function() return 'native-chat-channel' end}
            ISChat={instance={tabs={{tabID=0,chatMessages={native}}}},
                addLineInChat=function(m,tab) displayed[#displayed+1]=m;assert(tab==0) end}
            assert(Speech.flush() and #Speech.pending==0)
            assert(displayed[1].author=='Ratspit Ashlicker')
            assert(displayed[1].text=='Ratspit Ashlicker: Comrade, supplies are here.')
            Speech.flush();assert(#displayed==1)
        ''')

    def test_disconnect_and_reconnect_keep_same_actor_identity_inventory_and_task(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            a=Spawner.ensureForPlayer(player); a.x=8
            Spawner.setTask(a,'WAIT',{})
            online=list(); Spawner.ensureAll(false)
            assert(not a.removed and a.inventory[1] == 'kept-item')
            assert(saved.records.horse.position.x == 8 and saved.records.horse.task == 'WAIT')
            online=list({player}); b=Spawner.ensureForPlayer(player)
            assert(a == b and spawnCount == 1 and a.data.GoblinID == 'goblin.primary.horse')
        ''')

    def test_restart_recovers_record_without_resetting_task_on_every_scan(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            a=Spawner.ensureForPlayer(player); Spawner.setTask(a,'WAIT',{})
            a.x=20; Spawner.allBodies()
            changes=a.taskChanges
            Spawner.allBodies(); Spawner.allBodies()
            assert(a.taskChanges == changes)
            package.loaded['GoblinSurvivor/GoblinSpawner']=nil
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            assert(Spawner.ensureForPlayer(player) == a and spawnCount == 1)
            assert(saved.records.horse.position.x == 20 and a.data.GoblinTask == 'WAIT')
        ''')

    def test_recreation_uses_saved_position_and_rejects_old_generation(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            old=Spawner.ensureForPlayer(player); old.x=20; Spawner.allBodies()
            zombies=list(); package.loaded['GoblinSurvivor/GoblinSpawner']=nil
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            a=Spawner.ensureForPlayer(player)
            assert(a.x == 20 and a.data.GoblinGeneration == 2)
            zombies:add(old); Spawner.allBodies()
            assert(old.removed and not a.removed)
        ''')

    def test_two_owners_have_distinct_persistent_records(self):
        self.lua.execute('''
            second=actor(30,0,0)
            function second:getUsername() return 'friend' end
            online=list({player,second})
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            Spawner.ensureAll(false); Spawner.ensureAll(false)
            assert(spawnCount == 2)
            assert(saved.records.horse.npc_id ~= saved.records.friend.npc_id)
            assert(#saved.companions == 2)
        ''')

    def test_speaking_does_not_replace_follow_task(self):
        self.lua.execute('''
            package.loaded['GoblinSurvivor/GoblinLoot']={}
            Body.say=function() return true,'said' end
            Body.ensureWeapon=function() return true,'equipped' end
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            a=Spawner.ensureForPlayer(player)
            Brain=require('GoblinSurvivor/GoblinBrain')
            assert(Brain.setTask(a,'SPEAK',{text='hello'}))
            assert(Brain.setTask(a,'EQUIP',{}))
            assert(saved.records.horse.task == 'FOLLOW' and a.data.GoblinTask == 'FOLLOW')
        ''')

    def test_follow_command_is_accepted_and_persisted_while_squares_are_unavailable(self):
        self.lua.execute('''
            Spawner=require('GoblinSurvivor/GoblinSpawner'); Spawner.load()
            a=Spawner.ensureForPlayer(player)
            Body.setCombatPose=function() end
            Brain=require('GoblinSurvivor/GoblinBrain')
            squareUnavailable=true
            local accepted,detail=Brain.setTask(a,'FOLLOW',{owner='horse'})
            assert(accepted and detail=='follow queued; waiting for owner or world data',
                tostring(accepted)..' '..tostring(detail)..' gap='..tostring(math.abs(a.x-player.x)))
            assert(saved.records.horse.task=='FOLLOW' and a.data.GoblinTask=='FOLLOW')
            local Movement=require('GoblinSurvivor/GoblinMovement')
            assert(Movement.snapshot(a).task=='FOLLOW')
            squareUnavailable=false
            player.x=20
            Movement.update(a,clock+250)
            assert(a.pathCalls>=1 and Movement.snapshot(a).task=='FOLLOW')
        ''')


if __name__ == '__main__':
    unittest.main()
