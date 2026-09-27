from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "tools/probes/Milestone3KeyedContainerPersistenceProbe.lua"
CLIENT = ROOT / "tools/probes/Milestone3KeyedContainerPersistenceObserver.lua"


class KeyedContainerPersistenceProbeTests(unittest.TestCase):
    def test_probe_sources_compile_as_lua(self):
        lua = LuaRuntime()
        self.assertIsNotNone(lua.eval("loadstring")(SERVER.read_text()))
        self.assertIsNotNone(lua.eval("loadstring")(CLIENT.read_text()))

    def test_fixture_registration_precedes_lock_packets(self):
        source = SERVER.read_text()
        registered = source.index("square:AddSpecialObject(t.crate)")
        transmitted = source.index("t.crate:transmitCompleteItemToClients()")
        key_set = source.index("t.crate:setKeyId(keyId)")
        padlocked = source.index("t.crate:setLockedByPadlock(true)")
        self.assertLess(registered, transmitted)
        self.assertLess(transmitted, key_set)
        self.assertLess(key_set, padlocked)

    def test_normal_task_is_held_then_resumed_without_redispatch(self):
        source = SERVER.read_text()
        self.assertEqual(
            source.count('Brain.setTask(body,"GAIN_ACCESS",{target={kind="CONTAINER"}})'),
            1,
        )
        self.assertIn('mode=="hold-for-save"', source)
        self.assertIn('mode=="resume"', source)
        self.assertIn("if not witnessReady() then", source)
        self.assertIn("payload.m3_keyed_persistence=true", source)
        self.assertIn("restored_payload=true", source)
        self.assertIn("result=original(body,task,payload,now)", source)

    def test_restart_checks_exact_content_key_and_lock_conservation(self):
        source = SERVER.read_text()
        for required in (
            '"saved content identity changed"',
            '"saved padlock state changed"',
            '"saved matching key identity missing"',
            '"saved matching key no longer grants access"',
            'contents_unchanged=',
            'key_identity=true',
            'key_retained=',
        ):
            self.assertIn(required, source)

    def test_clients_report_persisted_lock_and_contents(self):
        source = CLIENT.read_text()
        self.assertIn('command=="keyed-persistence"', source)
        self.assertIn("found:getContainer():getItems()", source)
        self.assertIn("found:isLockedByPadlock()", source)
        self.assertIn("found:getKeyId()", source)


if __name__ == "__main__":
    unittest.main()
