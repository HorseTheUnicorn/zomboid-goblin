"""Caretaker: home upkeep without orders, also while the owner is away (fixtures)."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / "mod/Contents/mods/GoblinSurvivor/42/media/lua"


class CaretakerTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().paths = ";".join((LUA / s / "?.lua").as_posix() for s in ("shared", "server", "client"))
        self.lua.execute('package.path=paths..";"..package.path')
        for filename in ("goblin_fixture.lua", "work_fixture.lua"):
            self.lua.execute((ROOT / "tests/lua" / filename).read_text())
        self.lua.execute('''
            worldHours=100; hourNow=12
            getGameTime=function() return {getWorldAgeHours=function() return worldHours end,
                getHour=function() return hourNow end} end
            Autonomy=require('GoblinSurvivor/GoblinAutonomy')
            Caretaker=require('GoblinSurvivor/GoblinCaretaker')
            started={}
            setTask=function(b,task,payload) started[#started+1]={task=task,payload=payload}; return true end
        ''')

    def test_power_duty_runs_offline_with_a_server_built_caretaker_payload(self):
        self.lua.execute('''
            gridOn=false
            a.data.GoblinTask='FOLLOW'; online=list()
            Autonomy.update(a,clock)
            assert(a.data.GoblinTask=='RESTORE_POWER', a.data.GoblinTask)
            assert(a.data.GoblinLastAutonomyAction=='CARETAKER_POWER')
            assert(a.data.GoblinTaskPayload.caretaker==true or a.data.GoblinCaretakerTask=='RESTORE_POWER')
            assert(a.data.GoblinHomestead.power=='none')
        ''')

    def test_grid_power_means_no_generator_and_backoff_stops_a_failing_duty(self):
        self.lua.execute('''
            gridOn=true
            assert(Caretaker.tick(a,setTask,clock)==false and #started==0)
            assert(a.data.GoblinHomestead.power=='grid')
            gridOn=false
            assert(Caretaker.tick(a,setTask,clock+20000) and started[1].task=='RESTORE_POWER')
            assert(started[1].payload.caretaker==true)
            Caretaker.onResult(a,'RESTORE_POWER',{success=false,code='NO_TARGET'})
            worldHours=102
            assert(Caretaker.tick(a,setTask,clock+40000)==false and #started==1) -- backing off
            worldHours=104
            assert(Caretaker.tick(a,setTask,clock+60000) and #started==2)
        ''')

    def test_crops_and_night_curtains_are_duties(self):
        self.lua.execute('''
            gridOn=true
            package.loaded['GoblinSurvivor/GoblinFarming']={needs=function() return {plants=4,water=2,harvest=0} end,
                waterAll=function() return 0 end}
            package.loaded['GoblinSurvivor/GoblinCurtains']={scopeAt=function() return {rooms={}} end,
                openCount=function() return 3 end}
            assert(Caretaker.tick(a,setTask,clock) and started[1].task=='FARM' and started[1].payload.job=='tend')
            package.loaded['GoblinSurvivor/GoblinFarming'].needs=function() return {plants=4} end
            assert(not Caretaker.tick(a,setTask,clock+20000)) -- daytime: curtains stay
            hourNow=22
            assert(Caretaker.tick(a,setTask,clock+40000) and started[2].task=='CLOSE_CURTAINS')
        ''')

    def test_catch_up_after_the_area_was_unloaded_and_report_to_the_owner(self):
        self.lua.execute('''
            gridOn=true
            local watered=0
            package.loaded['GoblinSurvivor/GoblinFarming']={needs=function() return {plants=5} end,
                waterAll=function() watered=watered+5; return 5 end}
            Caretaker.tick(a,setTask,clock)
            assert(watered==0)
            worldHours=130 -- nobody was near for 30 game hours
            Caretaker.tick(a,setTask,clock+20000)
            assert(watered==5 and a.data.GoblinCaretakerReport:find('watered 5 plant'))
        ''')

    def test_goblin_roams_150_tiles_of_home_and_owner_far_away_keeps_companion(self):
        self.lua.execute('''
            gridOn=true
            -- Within 150 tiles of home he roams freely; beyond it he walks back.
            a.data.GoblinBaseX=100; a.data.GoblinBaseY=100
            a.data.GoblinTask='FOLLOW'; online=list()
            Autonomy.update(a,clock)
            assert(a.data.GoblinTask~='RETURN_TO_BASE', a.data.GoblinTask)
            a.data.GoblinBaseX=800; a.data.GoblinBaseY=800
            a.data.GoblinTask='FOLLOW'
            Autonomy.update(a,clock+250)
            assert(a.data.GoblinTask=='RETURN_TO_BASE', a.data.GoblinTask)
            -- Owner online and idle far from the base: no upkeep trips home.
            a.data.GoblinTask='FOLLOW'; online=list({player})
            Autonomy.update(a,clock+250); Autonomy.update(a,clock+60000)
            assert(a.data.GoblinTask~='RETURN_TO_BASE')
            assert(a.data.GoblinLastAutonomyAction~='CARETAKER_POWER')
        ''')

    def test_only_caretaker_jobs_may_prepare_without_the_owner(self):
        self.lua.execute('''
            local Jobs=require('GoblinSurvivor/GoblinJobs')
            assert(Jobs.CARETAKER.RESTORE_POWER and Jobs.CARETAKER.FARM and not Jobs.CARETAKER.COOK)
            local payload,why=Jobs.prepare(a,nil,'COOK',{caretaker=true})
            assert(payload==nil and why:find('owner'))
            payload,why=Jobs.prepare(a,nil,'RESTORE_POWER',{})
            assert(payload==nil and why:find('owner'))
            payload,why=Jobs.prepare(a,nil,'RESTORE_POWER',{caretaker=true})
            assert(payload and payload.caretaker==true and payload.anchor.x==0, why)
        ''')


if __name__ == "__main__":
    unittest.main()
