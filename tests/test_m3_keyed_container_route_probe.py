"""Static checks for the live-verified two-client keyed-container route probe."""
from pathlib import Path
import hashlib
import unittest

from lupa.lua51 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "tools/probes/Milestone3KeyedContainerRouteProbe.lua"


class KeyedContainerRouteProbeTests(unittest.TestCase):
    def test_probe_compiles_as_lua(self):
        self.assertIsNotNone(LuaRuntime().eval("loadstring")(PROBE.read_text()))

    def test_matches_the_probe_recorded_in_the_milestone_3_evidence(self):
        # docs/MILESTONE3_CONTAINER_CHECK.md records this exact probe hash for
        # the passing 2026-09-27 two-client run.
        digest = hashlib.sha256(PROBE.read_bytes().replace(b"\r\n", b"\n")).hexdigest()
        doc = (ROOT / "docs/MILESTONE3_CONTAINER_CHECK.md").read_text()
        raw = hashlib.sha256(PROBE.read_bytes()).hexdigest()
        self.assertTrue(digest in doc or raw in doc, "probe changed since its recorded live run")

    def test_fixture_registration_precedes_lock_packets(self):
        source = PROBE.read_text()
        registered = source.index("square:AddSpecialObject(t.crate)")
        transmitted = source.index("t.crate:transmitCompleteItemToClients()")
        key_set = source.index("t.crate:setKeyId(id)")
        padlocked = source.index("t.crate:setLockedByPadlock(true)")
        self.assertLess(registered, transmitted)
        self.assertLess(transmitted, key_set)
        self.assertLess(key_set, padlocked)

    def test_uses_the_normal_task_and_never_moves_the_actor(self):
        source = PROBE.read_text()
        self.assertEqual(source.count('Brain.setTask(body,"GAIN_ACCESS",{target={kind="CONTAINER"}})'), 1)
        for forbidden in ("body:setX", "body:setY", "body:teleport"):
            self.assertNotIn(forbidden, source)

    def test_terminal_requires_conservation_and_cleans_up(self):
        source = PROBE.read_text()
        for required in ("contents_unchanged=", "key_retained=", "t.crate:isLockedByPadlock()",
                         "transmitRemoveItemFromSquare(t.crate)", 'getServerName()~="goblin-local"'):
            self.assertIn(required, source)


if __name__ == "__main__":
    unittest.main()
