"""Observer timing checks only; not multiplayer acceptance evidence."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime


class ContainerObserverTests(unittest.TestCase):
    def test_late_dispatch_still_observed_then_expires(self):
        lua = LuaRuntime()
        lua.execute('''
            clock=0;reads=0;placements=0
            function isClient() return true end
            function isServer() return false end
            function getTimestampMs() return clock end
            function getFileReader() return {
                readLine=function() return 'm3witness_54' end,close=function() end} end
            package.preload['GoblinSurvivor/GoblinClient']=function() return {} end
            Events={OnTick={Add=function(f) tick=f end},
                OnServerCommand={Add=function(f) message=f end}}
            function getPlayer() return {
                getUsername=function() return 'm3witness_54' end,
                getCurrentSquare=function() return {} end,
                teleportTo=function() placements=placements+1 end} end
            function getCell() return {
                getGridSquare=function() reads=reads+1;return nil end,
                getZombieList=function() return {size=function() return 0 end} end} end
            function print() end
        ''')
        source = Path(__file__).resolve().parents[1] / 'tools/probes/Milestone3ContainerPlacement.lua'
        lua.execute(source.read_text())
        lua.execute('''
            tick();clock=240000;tick();assert(reads==0 and placements==1)
            message('GoblinM3Probe','container',{x=1,y=2,z=0,id='test',phase='initial'})
            tick();assert(reads==1)
            clock=421001;tick();assert(reads==1)
            message('GoblinM3Probe','container',{x=1,y=2,z=0,id='test',phase='terminal'})
            tick();assert(reads==1)
        ''')


if __name__ == '__main__':
    unittest.main()
