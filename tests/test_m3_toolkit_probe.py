"""Probe control-flow tests only; not native inventory acceptance."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

PROBE = Path(__file__).resolve().parents[1] / 'tools/probes/Milestone3ToolkitProbe.lua'


class ToolkitProbeTests(unittest.TestCase):
    def runtime(self, repair=False, fail=False, fuel=False, persistence=False):
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
        if repair:
            lua.globals().failRepair = fail
            lua.execute('''
                function getFileReader()
                    local n=0
                    return {readLine=function() n=n+1
                        return n==1 and 'm3path_61' or 'repair-hammer' end,
                        close=function() end}
                end
                item.condition=8
                function item:getCondition() return self.condition end
                function item:getConditionMax() return 10 end
                function item:setCondition(value) self.condition=value end
                local tools=require('GoblinSurvivor/GoblinTools')
                tools.ensure=function()
                    if failRepair then return nil end
                    item.condition=10;return item
                end
            ''')
        if fuel:
            lua.globals().failFuel = fail
            lua.execute('''
                function getFileReader()
                    local n=0
                    return {readLine=function() n=n+1
                        return n==1 and 'm3path_61' or 'fuel-conservation' end,
                        close=function() end}
                end
                item.condition=8;item.fuel=0.2
                function item:getFullType() return 'Base.BlowTorch' end
                function item:IsDrainable() return true end
                function item:getCurrentUsesFloat() return self.fuel end
                function item:setUsedDelta(value) self.fuel=value end
                function item:getCondition() return self.condition end
                function item:setCondition(value) self.condition=value end
                local tools=require('GoblinSurvivor/GoblinTools')
                tools.types={'Base.BlowTorch'}
                tools.ensure=function()
                    item.condition=10
                    if failFuel then item.fuel=1 end
                    return item
                end
            ''')
        if persistence:
            lua.execute('''
                function getFileReader()
                    local n=0
                    return {readLine=function() n=n+1
                        return n==1 and 'm3toolkit_27' or 'fresh-persistence' end,
                        close=function() end}
                end
                item.fuel=0
                function item:IsDrainable() return true end
                function item:getCurrentUsesFloat() return self.fuel end
                function item:getFluidContainer() return nil end
                local tools=require('GoblinSurvivor/GoblinTools')
                tools.ensureKit=function()
                    if failFuel then item.fuel=1 end
                    return true,1
                end
                local bodyModule=require('GoblinSurvivor/GoblinBody')
                bodyModule.owner=function() return 'm3toolkit_27' end
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

    def test_repair_fixture_restores_original_condition_on_success_and_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail):
                lua = self.runtime(repair=True, fail=fail)
                lua.execute('tick();assert(item.condition==8)')
                logs = '\n'.join(lua.globals().logs.values())
                self.assertIn('repair_fixture_restored=true', logs)
                self.assertEqual('repair_error=' in logs, fail)

    def test_fuel_fixture_restores_contents_even_when_maintenance_refills(self):
        for fail in (False, True):
            with self.subTest(fail=fail):
                lua = self.runtime(fuel=True, fail=fail)
                lua.execute('tick();assert(item.condition==8 and item.fuel==0.2)')
                logs = '\n'.join(lua.globals().logs.values())
                self.assertIn('fuel_fixture_restored=true', logs)
                self.assertEqual('fuel_error=' in logs, fail)

    def test_fresh_persistence_mode_requires_empty_idempotent_kit(self):
        lua = self.runtime(persistence=True)
        lua.execute('tick()')
        logs = '\n'.join(lua.globals().logs.values())
        self.assertIn('fresh_persistence=true', logs)
        self.assertIn('empty_contents=true', logs)
        self.assertIn('inventory_identity_unchanged=true', logs)
