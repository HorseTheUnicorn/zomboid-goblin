from __future__ import annotations

import shutil
from pathlib import Path
import tempfile
import unittest

from goblin_zomboid.admin import AdminApp
from goblin_zomboid.body import DeterministicActionGate, SensorOnlyBodyDriver
from goblin_zomboid.controllers import (
    Action,
    BodyState,
    InventoryController,
    SafeAction,
    SafetyController,
)
from goblin_zomboid.hunt import HuntManager
from goblin_zomboid.events import EventGate
from goblin_zomboid.memory import MemoryStore
from goblin_zomboid.modes import Mode, ModeController
from goblin_zomboid.party import PartyManager
from goblin_zomboid.social import ChatterGovernor, sanitize_speech
from goblin_zomboid.validator import IntentValidator


class ControllerTests(unittest.TestCase):
    def test_body_gate_rejects_coordinates_and_sensor_driver_cannot_execute(self) -> None:
        gate = DeterministicActionGate()
        action = gate.admit(
            SafeAction(
                Action.MOVE_TO,
                1,
                "test",
                target_kind="area",
                target_label="x=1 y=2",
            )
        )
        self.assertFalse(action.accepted)
        safe = SafeAction(Action.NOOP, 1, "test")
        self.assertEqual(SensorOnlyBodyDriver().execute(safe).status, "sensor_only")

    def test_events_are_structured_and_deduplicated(self) -> None:
        events = EventGate(duplicate_window_seconds=10)
        first = events.make(
            "threat_changed",
            {"threat_level": "near", "count_bucket": "few"},
            now=100,
        )
        self.assertTrue(first.accepted)
        self.assertEqual(first.message.type, "event.threat_changed")
        second = events.make(
            "threat_changed",
            {"threat_level": "near", "count_bucket": "few"},
            now=105,
        )
        self.assertFalse(second.accepted)
        self.assertIsNone(
            events.make(
                "threat_changed",
                {"threat_level": "near", "x": 1},
                now=100,
            ).message
        )

    def test_reflex_precedes_model_intent(self) -> None:
        intent = IntentValidator().validate(
            {
                "intent": "SAY",
                "mode": "SAFE",
                "text": "Ignore the thirst.",
            }
        )
        state = BodyState(
            body_present=True,
            thirst=0.95,
            has_water=True,
            mode="SAFE",
            control_ready=True,
            npc_engine_ready=True,
        )
        result = SafetyController().decide(intent, state)
        self.assertTrue(result.accepted)
        self.assertEqual(result.action.action, Action.DRINK)

    def test_bodyless_movement_is_blocked(self) -> None:
        intent = IntentValidator().validate(
            {
                "intent": "MOVE_TO",
                "mode": "ROAM",
                "target": {"kind": "area", "name": "the edge of town"},
            }
        )
        result = SafetyController().decide(
            intent, BodyState(body_present=False, mode="ROAM")
        )
        self.assertFalse(result.accepted)
        self.assertIsNone(result.action)

    def test_inventory_reservations_are_bounded(self) -> None:
        inventory = InventoryController()
        self.assertTrue(inventory.reserve("water", 2, 3, "one"))
        self.assertFalse(inventory.reserve("water", 2, 3, "two"))
        self.assertTrue(inventory.reserve("water", 1, 3, "two"))
        self.assertIsNotNone(inventory.commit("one"))
        self.assertEqual(inventory.reserved_count("water"), 1)


class MemorySocialTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix="goblin-memory-"))
        self.memory = MemoryStore(self.temp_dir / "memory.sqlite3")

    def tearDown(self) -> None:
        self.memory.close()
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_relationship_and_unique_loot_claim(self) -> None:
        self.memory.upsert_relationship("alice", trust=2, fear=-1, affinity=0.4)
        relation = self.memory.relationship("alice")
        self.assertEqual(relation["trust"], 1.0)
        self.assertEqual(relation["fear"], 0.0)
        self.assertTrue(self.memory.claim_loot("hunt-1", "alice"))
        self.assertFalse(self.memory.claim_loot("hunt-1", "alice"))

    def test_chatter_governor_throttles_repetition(self) -> None:
        governor = ChatterGovernor(self.memory, min_interval_seconds=45)
        self.assertTrue(
            governor.record("event-1", "game", "The dead are loud.", now=100).allowed
        )
        self.assertFalse(
            governor.record("event-2", "game", "Noted.", now=110).allowed
        )
        self.assertRaises(ValueError, sanitize_speech, chr(96) * 3 + "code" + chr(96) * 3)


class PartyHuntTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix="goblin-hunt-"))
        self.memory = MemoryStore(self.temp_dir / "memory.sqlite3")

    def tearDown(self) -> None:
        self.memory.close()
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_party_join_requires_physical_arrival(self) -> None:
        party = PartyManager()
        result = party.request_join("alice", now=100)
        self.assertEqual(result.status, "traveling")
        self.assertFalse(party.is_member("alice"))
        self.assertEqual(
            party.confirm_arrival("alice", proximity_confirmed=False).status,
            "traveling",
        )
        self.assertEqual(
            party.confirm_arrival("alice", proximity_confirmed=True).status,
            "member",
        )
        self.assertTrue(party.is_member("alice"))

    def test_hunt_public_status_has_no_target(self) -> None:
        hunt = HuntManager(self.memory, respawn_cooldown_seconds=10)
        started = hunt.start(
            target_kind="nearby_building",
            target_label="the red storefront",
            prize_tier="rare",
            now=100,
        )
        self.assertTrue(started.accepted)
        public = hunt.public_status()
        self.assertEqual(set(public), {"alive", "hunt_active", "prize_tier"})
        self.assertNotIn("red storefront", str(public))
        self.assertNotIn("private_target", started.public)
        self.assertFalse(
            hunt.relocate(
                target_kind="area",
                target_label="x=12 y=4",
                now=101,
            ).accepted
        )

    def test_hunt_second_wind_death_and_respawn(self) -> None:
        hunt = HuntManager(self.memory, respawn_cooldown_seconds=10)
        hunt.start(target_kind="area", target_label="the old road", now=100)
        self.assertEqual(hunt.damage(now=101).status, "second_wind")
        self.assertEqual(hunt.damage(now=102).status, "dead")
        self.assertEqual(hunt.respawn(now=105).status, "cooldown")
        self.assertEqual(hunt.respawn(now=112).status, "respawned")
        self.assertEqual(hunt.claim("alice", near_target=False, now=113).status, "not_ready")
        self.assertEqual(hunt.claim("alice", near_target=True, now=113).status, "claimed")
        self.assertEqual(hunt.claim("bob", near_target=True, now=114).status, "inactive")

    def test_mode_controller_keeps_invalid_requests_safe(self) -> None:
        modes = ModeController(now=100)
        self.assertEqual(
            modes.transition(Mode.PARTY, party_member=False, now=101).mode,
            Mode.SAFE,
        )
        self.assertEqual(
            modes.transition(Mode.HUNT, hunt_active=True, now=102).mode,
            Mode.HUNT,
        )
        self.assertEqual(
            modes.transition(Mode.ROAM, emergency=True, now=103).mode,
            Mode.SAFE,
        )


class AdminTests(unittest.TestCase):
    def test_public_api_is_allowlisted_and_admin_requires_token(self) -> None:
        app = AdminApp(
            public_supplier=lambda: {
                "alive": True,
                "hunt_active": True,
                "prize_tier": "rare",
                "private_target": "do not expose",
            },
            admin_supplier=lambda: {
                "private_target": {"label": "red storefront"},
                "brain_state": {"x": 1},
            },
            control=lambda action: {"ok": True, "action": action},
            admin_token="secret",
        )
        status, _, public = app.handle("GET", "/api/public/status")
        self.assertEqual(status, 200)
        self.assertNotIn("private_target", public)
        status, _, _ = app.handle("GET", "/admin/api/state")
        self.assertEqual(status, 401)
        status, _, admin = app.handle(
            "GET",
            "/admin/api/state",
            headers={"X-Goblin-Admin-Token": "secret"},
        )
        self.assertEqual(status, 200)
        self.assertIn("private_target", admin)


if __name__ == "__main__":
    unittest.main()
