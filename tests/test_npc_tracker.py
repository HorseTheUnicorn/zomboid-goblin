from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest

from goblin_zomboid.controllers import Action, SafeAction
from goblin_zomboid.entities import EntityRegistry, JobManager, SquadManager
from goblin_zomboid.ipc import BridgeStore
from goblin_zomboid.npc import NpcBodyDriver
from goblin_zomboid.protocol import decode_message
from goblin_zomboid.tracker import TrackerApp, TrackerStore
from goblin_zomboid.validator import IntentValidator


class NpcBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="goblin-npc-"))
        (self.directory / "bridge").mkdir()
        self.store = BridgeStore(self.directory / "bridge")

    def tearDown(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_driver_publishes_only_typed_npc_command(self) -> None:
        driver = NpcBodyDriver(self.store, control_ready=True, npc_engine_ready=True)
        result = driver.execute(
            SafeAction(Action.FOLLOW, 1, "follow an online player", "player", "alice")
        )
        self.assertTrue(result.accepted)
        item = next(self.store.iter_ready("commands"))
        message = self.store.read_ready(item)
        self.assertEqual(message.type, "command.npc_action")
        self.assertEqual(message.fields["npc_id"], "goblin.primary")
        self.assertNotIn("x", message.as_dict())

    def test_driver_rejects_wrong_npc_id_and_unready_engine(self) -> None:
        action = SafeAction(Action.NOOP, 1, "test", npc_id="other.npc")
        self.assertFalse(
            NpcBodyDriver(self.store, control_ready=True, npc_engine_ready=True)
            .execute(action).accepted
        )
        self.assertEqual(
            NpcBodyDriver(self.store).execute(
                SafeAction(Action.NOOP, 1, "test")
            ).status,
            "sensor_only",
        )

    def test_new_intents_have_bounded_ids_and_no_coordinates(self) -> None:
        intent = IntentValidator().validate(
            {
                "intent": "FORM_SQUAD",
                "mode": "PARTY",
                "leader": "goblin.primary",
                "requested_members": ["npc.guard.1"],
                "formation": "wedge",
            }
        )
        self.assertEqual(intent.data["formation"], "wedge")
        with self.assertRaises(ValueError):
            IntentValidator().validate(
                {"intent": "MOVE_TO", "mode": "ROAM", "target": {"kind": "area", "name": "x=2"}}
            )


class EntityAndTrackerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="goblin-tracker-"))

    def tearDown(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_squad_selection_preserves_critical_worker_and_job_allowlist(self) -> None:
        registry = EntityRegistry(npc_ids=("goblin.primary", "guard.1", "worker.1"))
        registry.npcs["worker.1"].critical_worker = True
        squad = SquadManager(registry).form(
            "squad.primary", leader="goblin.primary", requested=("worker.1", "guard.1"), formation="line"
        )
        self.assertEqual(squad.members, ("goblin.primary", "guard.1"))
        self.assertEqual(JobManager(registry).assign("guard.1", "guard"), "guard")
        with self.assertRaises(ValueError):
            JobManager(registry).assign("guard.1", "run_shell")

    def test_tracker_keeps_exact_map_data_out_of_brain_view(self) -> None:
        tracker = TrackerStore(self.directory / "tracker.sqlite3")
        tracker.record_state(
            {
                "npc_id": "goblin.primary",
                "x": 100,
                "y": 200,
                "threat": {"distance": "near", "distance_bucket": "near"},
                "secret": "must not be public",
                "npcs": [{"npc_id": "goblin.primary", "x": 100, "y": 200, "secret": "nope"}],
            }
        )
        self.assertEqual(tracker.state()["x"], 100)
        brain = tracker.brain_state()
        self.assertNotIn("x", brain)
        self.assertEqual(brain["threat"]["distance"], "near")
        public = TrackerApp(tracker).handle("GET", "/api/state")[2]
        self.assertNotIn("secret", public)
        self.assertNotIn("secret", public["npcs"][0])
        self.assertEqual(public["npcs"][0]["x"], 100)
        self.assertEqual(TrackerApp(tracker).handle("POST", "/api/state")[0], 405)
        tracker.close()


if __name__ == "__main__":
    unittest.main()
