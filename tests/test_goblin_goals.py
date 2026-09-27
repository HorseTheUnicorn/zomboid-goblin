"""Milestone 8 goal scheduler fixtures: deterministic results drive progress."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class GoalTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join(
            (LUA / side / "?.lua").as_posix() for side in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        self.lua.execute('''
            store={}
            saves=0
            body={data={GoblinTask='FOLLOW',GoblinTaskPayload={owner='horse'}}}
            package.loaded['GoblinSurvivor/GoblinBody']={owner=function() return 'horse' end,
                data=function(b) return b.data end}
            package.loaded['GoblinSurvivor/GoblinSpawner']={
                goalsForOwner=function() return store end,
                setGoalsForOwner=function(_,list) store=list;saves=saves+1;return true end}
            Goals=require('GoblinSurvivor/GoblinGoals')
            started={}
            function setTask(b,task,payload)
                started[#started+1]={task=task,payload=payload}
                b.data.GoblinTask=task; b.data.GoblinTaskPayload=payload
                return true,'queued'
            end
            function finish(code,now)
                local task=body.data.GoblinTask
                Goals.onResult(body,task,{done=true,success=code=='COMPLETE',code=code,detail=code},now,
                    body.data.GoblinTaskPayload.goal_id)
                body.data.GoblinTask='FOLLOW'; body.data.GoblinTaskPayload={owner='horse'}
            end
            idle={idle=true}
        ''')

    def test_goal_runs_steps_in_order_from_capability_results(self):
        self.lua.execute('''
            assert(Goals.add('horse','secure',0,1000))
            assert(Goals.tick(body,setTask,idle,1000))
            assert(started[1].task=='INSPECT_BASE' and started[1].payload.explicit_owner_order)
            assert(started[1].payload.goal_id==store[1].id and body.data.GoblinGoalActive==store[1].id)
            assert(Goals.tick(body,setTask,idle,1500)) -- running, nothing new started
            assert(#started==1)
            finish('COMPLETE',2000)
            assert(Goals.tick(body,setTask,idle,2000) and started[2].task=='MAINTAIN_BASE')
            finish('UNSUPPORTED',3000) -- partial maintenance is skipped, not retried
            assert(Goals.tick(body,setTask,idle,3000) and started[3].task=='CLOSE_CURTAINS')
            finish('COMPLETE',4000)
            assert(store[1].state=='DONE' and store[1].runs==1)
            assert(not Goals.tick(body,setTask,idle,5000))
        ''')

    def test_priority_selection_and_maintenance_cycle(self):
        self.lua.execute('''
            assert(Goals.add('horse','nails',0,1))
            assert(Goals.add('horse','repair',15,2))
            Goals.tick(body,setTask,idle,10)
            assert(started[1].task=='REPAIR_STRUCTURE')
            finish('COMPLETE',100)
            local repair=store[2]
            assert(repair.state=='DONE' and repair.next_at==100+15*60000)
            Goals.tick(body,setTask,idle,200)
            assert(started[2].task=='STOCKPILE' and started[2].payload.item=='Base.Nails')
            finish('COMPLETE',300)
            assert(not Goals.tick(body,setTask,idle,400))
            assert(Goals.tick(body,setTask,idle,100+15*60000))
            assert(started[3].task=='REPAIR_STRUCTURE')
        ''')

    def test_failures_replan_by_code(self):
        self.lua.execute('''
            assert(Goals.add('horse','repair',0,1))
            Goals.tick(body,setTask,idle,10)
            finish('MISSING_MATERIAL',20)
            assert(store[1].state=='WAITING' and store[1].next_at==20+600000)
            assert(not Goals.tick(body,setTask,idle,30))
            Goals.tick(body,setTask,idle,20+600000); finish('NO_PATH',700000)
            Goals.tick(body,setTask,idle,700000+120000); finish('BLOCKED',900000)
            assert(store[1].state=='FAILED' and store[1].steps[1].attempts==3)
            assert(Goals.add('horse','vehicle',0,2))
            Goals.tick(body,setTask,idle,1000000); finish('ENGINE_ERROR',1000001)
            assert(store[2].state=='FAILED')
        ''')

    def test_combat_and_recall_interrupt_without_consuming_attempts(self):
        self.lua.execute('''
            assert(Goals.add('horse','organize',0,1))
            Goals.tick(body,setTask,idle,10)
            assert(started[1].task=='DELIVER' and store[1].steps[1].attempts==1)
            assert(Goals.tick(body,setTask,{idle=true,threat=true},20))
            assert(started[2].task=='FOLLOW' and store[1].state=='WAITING')
            assert(store[1].steps[1].attempts==0 and store[1].last_code=='INTERRUPTED_COMBAT')
            assert(not Goals.tick(body,setTask,{idle=true,threat=true},10000))
            Goals.tick(body,setTask,idle,10000)
            assert(started[3].task=='DELIVER')
            assert(Goals.tick(body,setTask,{idle=false,recalled=true},11000))
            assert(store[1].last_code=='INTERRUPTED_RECALL' and body.data.GoblinTask=='FOLLOW')
            -- Not idle: nothing starts until the owner settles again.
            assert(not Goals.tick(body,setTask,{idle=false},20000))
        ''')

    def test_owner_override_or_lost_job_parks_goal(self):
        self.lua.execute('''
            assert(Goals.add('horse','secure',0,1))
            Goals.tick(body,setTask,idle,10)
            body.data.GoblinTask='WAIT'; body.data.GoblinTaskPayload={}
            assert(not Goals.tick(body,setTask,idle,20))
            assert(store[1].state=='WAITING' and body.data.GoblinGoalActive==nil)
            -- WAIT is explicit: goals never replace it.
            assert(not Goals.tick(body,setTask,idle,30))
            assert(#started==1)
        ''')

    def test_cancel_and_validation(self):
        self.lua.execute('''
            assert(not Goals.add('horse','conquer the world',0,1))
            assert(not Goals.add('horse','secure',5,1))
            assert(Goals.add('horse','secure',0,1))
            assert(Goals.add('horse','secure',30,2)) -- re-arms instead of duplicating
            assert(#store==1 and store[1].interval_ms==30*60000)
            assert(Goals.cancel('horse','all'))
            assert(store[1].state=='CANCELLED' and not Goals.tick(body,setTask,idle,50))
            assert(Goals.describe('horse')=='no goals')
        ''')


if __name__ == "__main__":
    unittest.main()
