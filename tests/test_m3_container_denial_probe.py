from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "tools/probes/Milestone3ContainerDenialProbe.lua"
CLIENT = ROOT / "tools/probes/Milestone3ContainerDenialObserver.lua"


class ContainerDenialProbeTests(unittest.TestCase):
    def test_probe_sources_compile_as_lua(self):
        lua = LuaRuntime()
        self.assertIsNotNone(lua.eval("loadstring")(SERVER.read_text()))
        self.assertIsNotNone(lua.eval("loadstring")(CLIENT.read_text()))

    def test_registered_fixture_precedes_lock_packet_and_uses_normal_task(self):
        source = SERVER.read_text()
        registered = source.index("square:AddSpecialObject(t.crate)")
        transmitted = source.index("t.crate:transmitCompleteItemToClients()")
        key_set = source.index("t.crate:setKeyId(t.keyId)")
        padlocked = source.index("t.crate:setLockedByPadlock(true)")
        self.assertLess(registered, transmitted)
        self.assertLess(transmitted, key_set)
        self.assertLess(key_set, padlocked)
        self.assertIn('Brain.setTask(body,"GAIN_ACCESS",{target={kind="CONTAINER"}})', source)

    def test_probe_checks_both_refusals_and_conservation(self):
        source = SERVER.read_text()
        for required in (
            'assertNormalRefusal(t,"missing-key")',
            'assertNormalRefusal(t,"code-lock")',
            '"refused task changed the active task"',
            '"refused task changed Goblin inventory"',
            '"refused task changed contents"',
            '"missing-key refusal changed padlock"',
            '"code refusal changed combination"',
        ):
            self.assertIn(required, source)
        self.assertNotIn('AddItem("Base.KeyPadlock")', source)

    def test_observer_reports_replica_lock_and_contents(self):
        source = CLIENT.read_text()
        self.assertIn('command=="container-denial"', source)
        self.assertIn("found:isLockedByPadlock()", source)
        self.assertIn("found:getLockedByCode()", source)
        self.assertIn("found:getContainer():getItems()", source)


if __name__ == "__main__":
    unittest.main()
