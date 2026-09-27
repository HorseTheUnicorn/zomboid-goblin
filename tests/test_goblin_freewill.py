"""Free will on the server: companion grant, situation report and recall."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class FreewillLuaTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join((LUA / s / "?.lua").as_posix() for s in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ("goblin_fixture.lua", "work_fixture.lua", "jobs_fixture.lua"):
            self.lua.execute((ROOT / "tests/lua" / filename).read_text())
        self.lua.execute('''
            Authority=require('GoblinSurvivor/Authority')
            d=Body.data(a)
        ''')

    def test_companion_grant_is_scoped_and_one_use(self):
        self.lua.execute('''
            assert(Authority.issueCompanion(a)==nil) -- free will not enabled
            d.GoblinFreewillEnabled=true
            local token=Authority.issueCompanion(a)
            assert(token and Authority.issueCompanion(a)==token) -- reused across heartbeats
            local ok={action='SORT_STORAGE',owner='horse',npc_id=d.GoblinID,freewill=true,authority_token=token}
            -- wrong Goblin, wrong owner, not a free-will message, or a commander-only action
            assert(not Authority.consume({action='SORT_STORAGE',owner='horse',npc_id='other',freewill=true,authority_token=token}))
            assert(not Authority.consume({action='SORT_STORAGE',owner='unicorn',npc_id=d.GoblinID,freewill=true,authority_token=token}))
            assert(not Authority.consume({action='SORT_STORAGE',owner='horse',npc_id=d.GoblinID,authority_token=token}))
            assert(not Authority.consume({action='FORM_SQUAD',owner='horse',npc_id=d.GoblinID,freewill=true,authority_token=token}))
            assert(Authority.consume(ok) and not Authority.consume(ok))
            local fresh=Authority.issueCompanion(a)
            assert(fresh and fresh~=token)
        ''')

    def test_situation_report_has_labels_and_events_but_no_coordinates(self):
        self.lua.execute('''
            Situation=require('GoblinSurvivor/GoblinSituation')
            Situation.note(a,'job','CHOP_WOOD COMPLETE: 4 logs')
            local r=Situation.build(a)
            assert(r.threats.level=='clear' and r.owner.online==true)
            assert(#r.events==1 and r.events[1].seq==1 and r.events[1].kind=='job')
            assert(r.goblin.freewill==false)
            local function walk(t)
                for k,v in pairs(t) do
                    assert(k~='x' and k~='y' and k~='z', 'coordinate leaked: '..tostring(k))
                    if type(v)=='table' then walk(v) end
                    assert(type(v)~='userdata')
                end
            end
            walk(r)
            for i=1,30 do Situation.note(a,'kills','x') end
            assert(#Situation.events[d.GoblinID]==16)
        ''')

    def test_free_will_work_is_recalled_when_the_owner_walks_off(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            d.GoblinFreewillEnabled=true
            d.GoblinTask='CHOP_WOOD';d.GoblinTaskPayload={};d.GoblinFreewill=true
            Autonomy.update(a,1000)
            assert(d.GoblinTask=='CHOP_WOOD') -- owner nearby: keep working
            player.x=player.x+40
            Autonomy.update(a,2000)
            assert(d.GoblinTask=='FOLLOW' and d.GoblinFreewillInterrupted=='recall' and d.GoblinFreewill==false)
        ''')

    def test_chores_wait_for_free_will_after_every_return_to_follow(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Config=require('GoblinSurvivor/Config')
            d.GoblinFreewillEnabled=true
            a.x,a.y=player.x-1,player.y  -- standing beside the owner
            d.GoblinTask='FOLLOW';d.GoblinTaskPayload={};d.GoblinTaskSequence=5
            Autonomy.update(a,1000)            -- owner seen
            local idleAt=1000+Config.autonomyIdleSeconds*1000+Config.freewillGraceSeconds*1000
            -- Goblin only just came back to FOLLOW (new sequence) after a long owner idle:
            d.GoblinTaskSequence=6
            local record=Autonomy.owners['horse']
            Autonomy.update(a,idleAt)
            -- The chore planner never ran (nextAt untouched): Qwen still has its window.
            assert(record.nextAt<idleAt, 'a chore stole the free-will window')
            local later=idleAt+Config.freewillGraceSeconds*1000+1
            Autonomy.update(a,later)
            assert(record.nextAt>later, 'filler chores should resume after the grace')
        ''')

    def test_follow_arrival_has_hysteresis(self):
        # Live: Goblin stood twitching as an idle owner's shuffle toggled him
        # between "arrived" (stop) and a fresh path every few frames.
        self.lua.execute('''
            Motion=require('GoblinSurvivor/GoblinLocomotion')
            player.x,player.y=5.5,0.5
            a.x,a.y=1.3,0.5  -- 4.2 tiles: not settled yet, so he walks
            local _,_,nav=Motion.followGoal(a,player,1000)
            assert(nav.goal_key~='arrived')
            a.x,a.y=2.4,0.5  -- reaches the follow radius and settles
            _,_,nav=Motion.followGoal(a,player,1100)
            assert(nav.goal_key=='arrived')
            a.x,a.y=1.3,0.5  -- owner shuffles a tile away: stays settled
            _,_,nav=Motion.followGoal(a,player,1200)
            assert(nav.goal_key=='arrived')
            a.x,a.y=0.5,0.5  -- 5 tiles: clearly left, so he follows again
            _,_,nav=Motion.followGoal(a,player,1300)
            assert(nav.goal_key~='arrived')
        ''')

    def test_explicit_orders_are_never_recalled(self):
        self.lua.execute('''
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            d.GoblinFreewillEnabled=true
            d.GoblinTask='CHOP_WOOD';d.GoblinTaskPayload={};d.GoblinFreewill=false
            Autonomy.update(a,1000)
            player.x=player.x+40
            Autonomy.update(a,2000)
            assert(d.GoblinTask=='CHOP_WOOD')
        ''')


if __name__ == "__main__":
    unittest.main()
