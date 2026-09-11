"""Execute production Lua in Lua 5.1 with small engine boundary doubles."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

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

    def test_follow_stops_once_at_three_tiles_and_resumes_when_owner_moves(self):
        self.lua.execute('''
            a=actor(6,0,0)
            goal,gap=Motion.followGoal(a,player)
            assert(goal and gap == 4)
            Motion.drive(a,goal,'WALK',clock)
            assert(a.pathCalls == 1)
            a.x=7.1
            goal=Motion.followGoal(a,player)
            assert(goal == nil)
            Motion.drive(a,goal,'IDLE',clock)
            assert(a.useless and a.cancelCalls == 1)
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
            assert(a.visuals:get(0):getItemType() == Config.npcVisualItemType)
            clock=clock+2000
            assert(Appearance.apply(a,clock)); assert(a.visuals:size() == 5 and a.resets == 1)
            a.visuals:clear(); clock=clock+2000
            assert(Appearance.apply(a,clock)); assert(a.visuals:size() == 5 and a.resets == 2)
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
