"""Regression coverage for the client-only friendly jumpscare exclusion."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class GoblinScareTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        paths = ";".join(
            (LUA / scope / "?.lua").as_posix()
            for scope in ("shared", "server", "client")
        )
        self.lua.globals().test_paths = paths
        self.lua.execute('package.path = test_paths .. ";" .. package.path')
        self.lua.execute((ROOT / "tests/lua/goblin_fixture.lua").read_text())
        self.lua.execute("V=require('GoblinSurvivor/GoblinVisibility')")

    def test_repeated_calls_add_each_ready_goblin_once_for_each_local_player(self):
        self.lua.execute(
            """
            clientMode=true
            local second=actor(11,0,0)
            online=list({player,second})
            local stacks={}
            local function stack()
                local s={values={}}
                function s:contains(value)
                    for _,item in ipairs(self.values) do if item==value then return true end end
                    return false
                end
                function s:add(value) self.values[#self.values+1]=value end
                return s
            end
            stacks[player]=stack();stacks[second]=stack()
            function player:getLastSpotted() return stacks[self] end
            function second:getLastSpotted() return stacks[self] end
            getNumActivePlayers=function() return 2 end
            getSpecificPlayer=function(index) return index==0 and player or second end
            local ordinary=actor(20,0,0)
            stacks[player]:add(ordinary)
            local goblin=actor(12,0,0)
            function goblin:getSquare() return {} end
            function goblin:isDead() return false end
            local state={npc_id='goblin.primary.horse',body_present=true}
            V.track(goblin,state,true,clock,true)
            assert(V.suppressScare(player,clock)==1)
            assert(#stacks[player].values==2 and stacks[player].values[1]==ordinary
                and stacks[player].values[2]==goblin)
            assert(V.suppressScare(player,clock+1)==0 and #stacks[player].values==2)
            assert(V.suppressScare(second,clock+1)==1 and #stacks[second].values==1)
            assert(V.suppressScare(second,clock+2)==0 and #stacks[second].values==1)
            """
        )

    def test_stale_removed_dead_unready_unconfirmed_and_nonlocal_entries_are_ignored(self):
        self.lua.execute(
            """
            clientMode=true
            local remote=actor(30,0,0)
            online=list({player})
            getNumActivePlayers=function() return 1 end
            getSpecificPlayer=function() return player end
            local spotted={values={}}
            function spotted:contains(value)
                for _,item in ipairs(self.values) do if item==value then return true end end
                return false
            end
            function spotted:add(value) self.values[#self.values+1]=value end
            function player:getLastSpotted() return spotted end
            local function body(square,dead)
                local value=actor(0,0,0)
                function value:getSquare() return square end
                function value:isDead() return dead end
                return value
            end
            local state={npc_id='goblin.primary.horse',body_present=true}
            V.track(body({},false),state,true,clock-2000,true)
            V.track(body(nil,false),state,true,clock,true)
            V.track(body({},true),state,true,clock,true)
            V.track(body({},false),state,true,clock,false)
            V.track(body({},false),state,false,clock,true)
            local bad=body({},false);V.track(bad,{body_present=true},true,clock,true)
            local ordinary=body({},false);spotted:add(ordinary)
            assert(V.suppressScare(player,clock)==0 and #spotted.values==1)
            assert(V.suppressScare(remote,clock)==0 and #spotted.values==1)
            clientMode=false
            assert(V.suppressScare(player,clock)==0 and #spotted.values==1)
            """
        )

    def test_source_installs_the_player_update_hook(self):
        source = (
            ROOT
            / "mod/Contents/mods/GoblinSurvivor/42/media/lua/client/GoblinSurvivor/GoblinClient.lua"
        ).read_text(encoding="utf-8")
        self.assertIn('EventHooks.install("client.friendly_scare", Events.OnPlayerUpdate', source)
        self.assertIn("Visibility.suppressScare(viewer, nowMs())", source)


if __name__ == "__main__":
    unittest.main()
