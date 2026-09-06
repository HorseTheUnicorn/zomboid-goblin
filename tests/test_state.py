from __future__ import annotations

import unittest

from goblin_zomboid.perception import build_agent_perception
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

    def test_brain_view_redacts_bridge_authority_capabilities(self) -> None:
        result = brain_view(
            {"authorized": True, "authority_token": "grant-secret", "token": "other"}
        )
        self.assertEqual(result, {"authorized": True})

    def test_agent_perception_keeps_logical_ids_and_drops_exact_locations(self) -> None:
        perception = build_agent_perception(
            {
                "npc_id": "goblin.primary",
                "alive": True,
                "body_present": True,
                "nearby_players": [{"id": "Alice", "online": True}],
                "npcs": [{
                    "npc_id": "npc.0001", "name": "Sarah", "x": 10, "y": 11,
                    "join_assist": True, "join_assist_username": "Alice",
                }],
                "base": {"id": "base.primary", "x": 20, "y": 21},
                "threat_level": "near",
                "ordinary_zombie_count": 2,
                "x": 100,
                "y": 200,
                "z": 0,
            },
            event={
                "type": "PLAYER_CHAT",
                "speaker_id": "player.alice",
                "text": "hello",
            },
        )
        self.assertEqual(perception["players"][0]["id"], "player.alice")
        self.assertNotIn("x", perception)
        self.assertNotIn("y", perception)
        self.assertNotIn("z", perception)
        self.assertNotIn("x", perception["survivors"][0])
        self.assertNotIn("y", perception["survivors"][0])
        self.assertTrue(perception["survivors"][0]["join_assist"])
        self.assertEqual(
            perception["survivors"][0]["join_assist_username"], "Alice"
        )
        self.assertNotIn("x", perception["base"])
        self.assertNotIn("y", perception["base"])
        self.assertEqual(perception["event"]["speaker_id"], "player.alice")

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
