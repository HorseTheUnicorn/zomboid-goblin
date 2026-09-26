"""Probe control-flow tests only; not native inventory acceptance."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

PROBE = Path(__file__).resolve().parents[1] / 'tools/probes/Milestone3ToolkitProbe.lua'


class ToolkitProbeTests(unittest.TestCase):
    def runtime(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
            logs={};function print(s) logs[#logs+1]=s end
            function isServer() return true end
            function getServerName() return 'goblin-local' end
            function getFileReader() return {
                readLine=function() return 'm3path_61' end,close=function() end} end
            clock=1000;function getTimestampMs() return clock end
            item={getFullType=function() return 'Base.Hammer' end,
                getID=function() return 42 end}
            items={size=function() return 1 end,get=function() return item end}
            body={getInventory=function() return {getItems=function() return items end} end}
            function getCell() return {getZombieList=function() return {
                size=function() return 1 end,get=function() return body end} end} end
            package.preload['GoblinSurvivor/GoblinBody']=function() return {
                isGoblin=function() return true end,owner=function() return 'm3path_61' end} end
            package.preload['GoblinSurvivor/GoblinTools']=function() return {
                types={'Base.Hammer'},reserved=function() return true end} end
            Events={OnTick={Add=function(f) tick=f end}}
        ''')
        lua.execute(PROBE.read_text())
        return lua

    def test_two_read_only_samples_stop_and_preserve_identity(self):
        lua = self.runtime()
        lua.execute('''
            tick();clock=30999;tick();assert(#logs==2)
            clock=31000;tick();assert(#logs==4)
            assert(logs[4]:find('reserved_identity_stable=true',1,true))
            clock=62000;tick();assert(#logs==4)
        ''')

    def test_replaced_item_is_not_reported_stable(self):
        lua = self.runtime()
        lua.execute('''
            tick();item.getID=function() return 43 end;clock=31000;tick()
            assert(logs[4]:find('reserved_identity_stable=false',1,true))
        ''')
