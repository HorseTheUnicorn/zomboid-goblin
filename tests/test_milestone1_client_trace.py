"""Client trace extraction preserves simulator observations without certifying a gate."""

import unittest

from tools.extract_milestone1_client_trace import parse_lines, summary


class ClientTraceTests(unittest.TestCase):
    def test_filters_actor_and_calculates_steps(self):
        lines = [
            "LOG > M1_CLIENT_TRACE t=1790190000000 client=horse id=goblin.horse "
            "online=7 remote=false x=1.0000 y=2.0000 z=0.0000 "
            "px=3.0000 py=4.0000 pz=0.0000 prun=false psprint=false",
            "LOG > M1_CLIENT_TRACE t=1790190000050 client=horse id=online.8 "
            "online=8 remote=false x=9.0000 y=9.0000 z=0.0000 "
            "px=3.0000 py=4.0000 pz=0.0000",
            "LOG > M1_CLIENT_TRACE t=1790190000100 client=horse id=goblin.horse "
            "online=7 remote=false x=1.3000 y=2.4000 z=0.0000 "
            "px=3.2000 py=4.0000 pz=0.0000 prun=true psprint=false",
        ]
        samples = parse_lines(lines, "horse", "goblin.horse")
        result = summary(samples)
        self.assertEqual(result["sample_count"], 2)
        self.assertEqual(result["online_ids"], [7])
        self.assertAlmostEqual(result["max_actor_step_tiles"], 0.5)
        self.assertEqual(result["max_interval_ms"], 100)
        self.assertEqual(result["moving_actor_steps"], 1)
        self.assertEqual(result["running_state_samples"], 2)
        self.assertAlmostEqual(result["running_player_distance_tiles"], 0.2)

    def test_legacy_trace_does_not_claim_running(self):
        base = ("M1_CLIENT_TRACE t={} client=horse id=goblin.horse "
                "online=7 remote=false x={} y=2.0000 z=0.0000 "
                "px={} py=4.0000 pz=0.0000")
        samples = parse_lines([
            base.format(1790190000000, "1.0000", "3.0000"),
            base.format(1790190000100, "1.5000", "3.5000"),
        ], "horse", "goblin.horse")
        self.assertIsNone(samples[0]["player_running"])
        self.assertEqual(summary(samples)["running_state_samples"], 0)
        self.assertEqual(summary(samples)["running_player_distance_tiles"], 0)

    def test_accepts_installed_build_42_log_terminator(self):
        prefix = ("LOG > M1_CLIENT_TRACE t={} client=horse id=goblin.horse "
                  "online=7 remote=false x={} y=2.0000 z=0.0000 "
                  "px=3.0000 py=4.0000 pz=0.0000 prun=false psprint=false.")
        samples = parse_lines([prefix.format(1790190000000, "1.0000"),
                               prefix.format(1790190000100, "1.5000")],
                              "horse", "goblin.horse")
        self.assertEqual(len(samples), 2)

    def test_filters_native_incarnation_before_summarizing_motion(self):
        base = ("M1_CLIENT_TRACE t={} client=horse id=goblin.horse "
                "online={} remote=false x={} y=0.0000 z=0.0000 "
                "px={} py=0.0000 pz=0.0000 prun=true psprint=false")
        lines = [base.format(100, 7, "1.0000", "0.0000"),
                 base.format(200, 7, "1.5000", "0.5000"),
                 base.format(10000, 9, "40.0000", "39.0000"),
                 base.format(10100, 9, "40.5000", "39.5000")]
        samples = parse_lines(lines, "horse", "goblin.horse", online_id=9)
        result = summary(samples)
        self.assertEqual(result["online_ids"], [9])
        self.assertEqual(result["max_interval_ms"], 100)
        self.assertAlmostEqual(result["max_actor_step_tiles"], 0.5)

    def test_accepts_outfit_diagnostics_without_changing_motion(self):
        base = ("M1_CLIENT_TRACE t={} client=horse id=goblin.horse "
                "online=7 remote=false x=1 y=2 z=0 px=3 py=4 pz=0 "
                "prun=true psprint=false outfit={} roster_outfit=14156199.")
        samples = parse_lines([base.format(100, 14156199),
                               base.format(200, 14188967)], "horse", "goblin.horse")
        self.assertEqual(len(samples), 2)
        self.assertTrue(samples[1]["player_running"])
        self.assertEqual(summary(samples)["max_actor_step_tiles"], 0)

    def test_rejects_nonmonotonic_and_malformed_lines(self):
        line = ("M1_CLIENT_TRACE t=1790190000000 client=horse id=goblin.horse "
                "online=7 remote=false x=1.0000 y=2.0000 z=0.0000 "
                "px=3.0000 py=4.0000 pz=0.0000")
        with self.assertRaisesRegex(ValueError, "nonmonotonic"):
            parse_lines([line, line], "horse", "goblin.horse")
        with self.assertRaisesRegex(ValueError, "malformed"):
            parse_lines([line, "M1_CLIENT_TRACE t=broken"], "horse", "goblin.horse")
        with self.assertRaisesRegex(ValueError, "malformed"):
            parse_lines([line, line.replace("pz=0.0000", "pz=0.0000 prun=maybe psprint=false")],
                        "horse", "goblin.horse")


if __name__ == "__main__":
    unittest.main()
