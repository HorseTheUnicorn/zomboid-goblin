from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import threading
import unittest
from urllib.request import urlopen

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

    def test_privileged_driver_action_requires_and_carries_authority_grant(self) -> None:
        driver = NpcBodyDriver(
            self.store, control_ready=True, npc_engine_ready=True
        )
        action = SafeAction(
            Action.FORM_SQUAD,
            2,
            "authorized expedition request",
            leader="Alice",
            members=("goblin.primary",),
            formation="loose",
            squad_id="squad.primary",
        )
        self.assertFalse(driver.execute(action).accepted)
        result = driver.execute(action, authority_token="grant-test-1")
        self.assertTrue(result.accepted)
        item = next(self.store.iter_ready("commands"))
        message = self.store.read_ready(item)
        self.assertEqual(message.fields["authority_token"], "grant-test-1")
        self.assertNotIn("authority_token", message.fields["controller_action"])

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

    def test_human_leader_gets_goblin_and_count_resolves_deterministically(self) -> None:
        registry = EntityRegistry(
            npc_ids=("goblin.primary", "guard.1", "worker.1"),
            player_ids=("Alice",),
        )
        registry.npcs["guard.1"].role = "guard"
        registry.npcs["worker.1"].role = "scout"
        squad = SquadManager(registry, minimum_base_guards=1).form(
            "squad.primary", leader="Alice", requested=1, formation="column"
        )
        self.assertEqual(squad.leader_player, "Alice")
        self.assertEqual(squad.goblin_member, "goblin.primary")
        self.assertEqual(squad.members, ("goblin.primary", "worker.1"))
        blocked = SquadManager(registry, minimum_base_guards=1).form(
            "squad.guard", leader="Alice", requested=["guard.1"], formation="loose"
        )
        self.assertEqual(blocked.members, ("goblin.primary",))


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

    def test_tracker_stream_sends_initial_snapshot_and_live_update(self) -> None:
        tracker = TrackerStore(self.directory / "stream.sqlite3")
        tracker.record_state({"npc_id": "goblin.primary", "npc_alive": False})
        app = TrackerApp(tracker, stream_seconds=30)
        server = app.server("127.0.0.1", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        response = None
        try:
            response = urlopen(
                f"http://127.0.0.1:{server.server_port}/api/stream", timeout=3
            )
            initial: list[bytes] = []
            while b"event: snapshot\n" not in b"".join(initial):
                line = response.readline()
                self.assertNotEqual(line, b"")
                initial.append(line)
            tracker.record_state({"npc_id": "goblin.primary", "npc_alive": True})
            update: list[bytes] = []
            while b"event: update\n" not in b"".join(update):
                line = response.readline()
                self.assertNotEqual(line, b"")
                update.append(line)
            self.assertIn(b"event: update\n", b"".join(update))
            self.assertIn(b"npc_alive", b"".join(update))
        finally:
            if response is not None:
                response.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
            tracker.close()


if __name__ == "__main__":
    unittest.main()
