from __future__ import annotations

import unittest

from goblin_zomboid.state import admin_view, brain_view, public_view


class StateViewTests(unittest.TestCase):
    def test_brain_view_redacts_exact_world_data(self) -> None:
        state = {
            "alive": True,
            "location_bucket": "north",
            "x": 100,
            "y": 200,
            "z": 0,
            "route": [{"x": 1, "y": 2}],
            "threat": {"distance": 3, "distance_bucket": "near"},
            "inventory": {"food": 2},
        }
        result = brain_view(state)
        self.assertNotIn("x", result)
        self.assertNotIn("y", result)
        self.assertNotIn("route", result)
        self.assertNotIn("distance", result["threat"])
        self.assertEqual(result["location_bucket"], "north")
        self.assertEqual(result["threat"]["distance_bucket"], "near")

    def test_public_view_is_an_explicit_allowlist(self) -> None:
        result = public_view(
            {
                "alive": True,
                "hunt_active": True,
                "prize_tier": "rare",
                "location_bucket": "north",
                "x": 100,
                "secret": "no",
            }
        )
        self.assertEqual(
            result,
            {"alive": True, "hunt_active": True, "prize_tier": "rare"},
        )

    def test_admin_view_is_a_copy(self) -> None:
        state = {"alive": True, "nested": {"value": 1}}
        result = admin_view(state)
        result["nested"]["value"] = 2
        self.assertEqual(state["nested"]["value"], 1)


if __name__ == "__main__":
    unittest.main()

