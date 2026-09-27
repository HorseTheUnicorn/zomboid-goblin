from pathlib import Path
import unittest


PROBE = Path(__file__).resolve().parents[1] / "tools/probes/Milestone3GateRouteProbe.lua"


class GateRouteProbeTests(unittest.TestCase):
    def test_fixture_is_registered_before_syncing_lock_fields(self):
        source = PROBE.read_text()
        registered = source.index("square:AddSpecialObject(t.gate)")
        transmitted = source.index("t.gate:transmitCompleteItemToClients()")
        key_set = source.index("t.gate:setKeyId(id)")
        padlocked = source.index("t.gate:setLockedByPadlock(true)")

        self.assertLess(registered, transmitted)
        self.assertLess(transmitted, key_set)
        self.assertLess(key_set, padlocked)


if __name__ == "__main__":
    unittest.main()
