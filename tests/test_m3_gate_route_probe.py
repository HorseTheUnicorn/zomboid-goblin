from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


PROBE = Path(__file__).resolve().parents[1] / "tools/probes/Milestone3GateRouteProbe.lua"
OBSERVER = Path(__file__).resolve().parents[1] / "tools/probes/Milestone3GateRouteObserver.lua"


class GateRouteProbeTests(unittest.TestCase):
    def test_probe_sources_compile_as_lua(self):
        lua = LuaRuntime()
        self.assertIsNotNone(lua.eval("loadstring")(PROBE.read_text()))
        self.assertIsNotNone(lua.eval("loadstring")(OBSERVER.read_text()))

    def test_fixture_is_registered_before_syncing_lock_fields(self):
        source = PROBE.read_text()
        registered = source.index("center:AddSpecialObject(t.gate)")
        transmitted = source.index("t.gate:transmitCompleteItemToClients()")
        key_set = source.index("t.gate:setKeyId(lockId)")
        padlocked = source.index("t.gate:setLockedByPadlock(true)")

        self.assertLess(registered, transmitted)
        self.assertLess(transmitted, key_set)
        self.assertLess(key_set, padlocked)

    def test_fixture_forces_normal_route_without_moving_actor_directly(self):
        source = PROBE.read_text()
        self.assertIn("function(module,command,player,args)", source)
        self.assertIn("east/south/west leaves the north gate as the only physical exit", source)
        self.assertEqual(
            source.count('Brain.setTask,body,"GAIN_ACCESS",{target={kind="YARD"}}'),
            1,
        )
        self.assertNotIn("body:setX", source)
        self.assertNotIn("body:setY", source)
        self.assertNotIn("body:setZ", source)
        self.assertNotIn("body:teleport", source)

    def test_terminal_requires_crossing_and_native_padlock_conservation(self):
        source = PROBE.read_text()
        for required in (
            "local crossed=body:getCurrentSquare()==t.destination",
            'result.code=="COMPLETE"',
            "not t.gate:isLockedByPadlock()",
            "t.gate:getKeyId()==-1",
            "keyConsumed and outputs==1",
            'notify(t,"terminal",success)',
        ):
            self.assertIn(required, source)

    def test_two_client_observer_requires_same_gate_and_side_change(self):
        source = OBSERVER.read_text()
        self.assertIn('command=="gate-route"', source)
        self.assertIn("square:getSpecialObjects()", source)
        self.assertIn("GoblinM3GateRouteID==args.id", source)
        self.assertIn('instanceof(object,"IsoThumpable") and object:isDoor()', source)
        self.assertIn('return fallback,"native-door"', source)
        self.assertIn('side=="from" and open==false and padlocked==true', source)
        self.assertIn('side=="to" and open==true and padlocked==false', source)


if __name__ == "__main__":
    unittest.main()
