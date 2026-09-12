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

    def test_stationary_actor_is_retried_without_restart_every_frame(self):
        self.lua.execute('''
            a=actor(0,0,0); goal={x=10,y=0,z=0}
            for i=0,50 do Motion.drive(a,goal,'WALK',clock+i*100) end
            assert(a.pathCalls == 1)
            Motion.drive(a,goal,'WALK',clock+6100)
            assert(a.pathCalls == 2 and Motion.paths[a].failures == 1)
        ''')

    def test_nearby_move_to_uses_walk_instead_of_idle(self):
        self.lua.execute('''
            a=actor(0,0,0); a.data={GoblinNPC=true,GoblinOwner='horse'}
            Movement=require('GoblinSurvivor/GoblinMovement')
            assert(Movement.command(a,'MOVE_TO',{x=2,y=0,z=0}))
            assert(a.data.GoblinMoveType == 'WALK' and a.pathCalls == 1)
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
            assert(Motion.moveType(nil,1,player)=='IDLE')
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


if __name__ == '__main__':
    unittest.main()
