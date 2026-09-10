from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest

from goblin_zomboid.config import AgentConfig
from goblin_zomboid.protocol import make_message
from goblin_zomboid.service import GoblinService
from goblin_zomboid.validator import IntentValidator


class FakeQwen:
    def __init__(self, intent: str = "FOLLOW") -> None:
        self.intent = intent
        self.intent_contexts: list[object] = []
        self.speech_contexts: list[object] = []

    def propose_speech(self, context: object) -> str:
        self.speech_contexts.append(context)
        return "Comrade, I have heard you. The canned beans shall be organized."

    def propose_intent(self, context: object):
        self.intent_contexts.append(context)
        if self.intent == "SET_BASE":
            payload = {"intent": "SET_BASE", "mode": "SAFE"}
        elif self.intent == "LOOT_AREA":
            payload = {
                "intent": "LOOT_AREA",
                "mode": "ROAM",
                "target": {"kind": "current_position", "name": "current area"},
                "loot_focus": "surprise",
            }
        else:
            payload = {
                "intent": "FOLLOW",
                "mode": "PARTY",
                "target": {"kind": "player", "player": "speaker"},
            }
        return IntentValidator().validate(payload)


class BrokenQwen:
    def propose_speech(self, _context: object) -> str:
        from goblin_zomboid.qwen import QwenError
        raise QwenError("speech outage")

    def propose_intent(self, _context: object):
        from goblin_zomboid.qwen import QwenError
        raise QwenError("intent outage")


class NpcServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="goblin-service-npc-"))
        self.bridge = self.directory / "bridge"
        self.bridge.mkdir()
        self.config = AgentConfig(
            bridge_root=self.bridge,
            enabled=True,
            heartbeat_seconds=1,
            pz_timeout_seconds=30,
            start_paused=False,
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.directory, ignore_errors=True)

    def _service(self, qwen: object) -> GoblinService:
        return GoblinService(
            self.config,
            memory_path=self.directory / "memory.sqlite3",
            qwen=qwen,
            clock=lambda: 2_000.0,
        )

    def _publish_state(self, service: GoblinService) -> None:
        service.store.publish_runtime(
            "zomboid-heartbeat",
            make_message(
                "runtime.heartbeat",
                timestamp_ms=2_000_000,
                body_mode="npc",
                companion_count=2,
            ),
        )
        service.store.publish_runtime(
            "zomboid-state",
            make_message(
                "runtime.state",
                timestamp_ms=2_000_000,
                companions=[
                    {
                        "npc_id": "goblin.primary.alice",
                        "owner": "Alice",
                        "alive": True,
                        "body_present": True,
                        "body_mode": "npc",
                        "control_ready": True,
                        "npc_engine_ready": True,
                        "mode": "PARTY",
                        "weapon_ready": True,
                        "x": 100,
                        "y": 200,
                    },
                    {
                        "npc_id": "goblin.primary.bob",
                        "owner": "Bob",
                        "alive": True,
                        "body_present": True,
                        "body_mode": "npc",
                        "control_ready": True,
                        "npc_engine_ready": True,
                        "mode": "PARTY",
                        "weapon_ready": True,
                    },
                ],
                nearby_players=[{"id": "Alice"}, {"id": "Bob"}],
            ),
        )

    def _publish_chat(self, service: GoblinService, speaker: str, text: str, stem: str) -> None:
        service.store.publish(
            "events",
            make_message(
                "event.chat",
                timestamp_ms=2_000_000,
                speaker=speaker,
                text=text,
                authorized=False,
            ),
            stem=stem,
        )

    def _commands(self, service: GoblinService):
        commands = []
        for item in service.store.iter_ready("commands"):
            commands.append(service.store.read_ready(item))
        return commands

    def test_addressed_chat_routes_reply_and_action_to_speakers_goblin(self) -> None:
        qwen = FakeQwen("FOLLOW")
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, follow me.", "alice-chat")
            result = service.run_once()
            self.assertEqual(result.status, "npc_command_published")
            commands = self._commands(service)
            self.assertEqual({cmd.fields["action"] for cmd in commands}, {"SAY", "FOLLOW"})
            self.assertTrue(all(cmd.fields["npc_id"] == "goblin.primary.alice" for cmd in commands))
            self.assertTrue(all(cmd.fields["owner"] == "Alice" for cmd in commands))
            self.assertEqual(qwen.intent_contexts[0]["controlled_npc_id"], "goblin.primary.alice")
            self.assertNotIn("x", qwen.intent_contexts[0])
            self.assertNotIn("y", qwen.intent_contexts[0])
        finally:
            service.close()

    def test_second_player_gets_a_different_goblin_id(self) -> None:
        qwen = FakeQwen("LOOT_AREA")
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Bob", "Goblin, loot this place and bring it home.", "bob-chat")
            result = service.run_once()
            self.assertEqual(result.status, "npc_command_published")
            commands = self._commands(service)
            self.assertTrue(all(cmd.fields["npc_id"] == "goblin.primary.bob" for cmd in commands))
            self.assertIn("LOOT_AREA", {cmd.fields["action"] for cmd in commands})
        finally:
            service.close()

    def test_set_base_is_a_normal_per_player_intent(self) -> None:
        qwen = FakeQwen("SET_BASE")
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, this is our base. Remember it.", "base-chat")
            result = service.run_once()
            self.assertEqual(result.status, "npc_command_published")
            actions = {cmd.fields["action"] for cmd in self._commands(service)}
            self.assertIn("SET_BASE", actions)
        finally:
            service.close()

    def test_ordinary_heartbeat_does_not_spend_qwen_tokens(self) -> None:
        qwen = FakeQwen()
        service = self._service(qwen)
        try:
            self._publish_state(service)
            first = service.run_once()
            second = service.run_once()
            self.assertEqual(first.status, "npc_steady")
            self.assertEqual(second.status, "npc_steady")
            self.assertEqual(qwen.intent_contexts, [])
            self.assertEqual(qwen.speech_contexts, [])
        finally:
            service.close()

    def test_coordinates_are_removed_before_qwen_sees_companion_state(self) -> None:
        qwen = FakeQwen()
        service = self._service(qwen)
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, come here.", "safe-chat")
            service.run_once()
            context = qwen.intent_contexts[0]
            self.assertNotIn("x", context)
            self.assertNotIn("y", context)
        finally:
            service.close()

    def test_qwen_outage_does_not_break_server_owned_companion(self) -> None:
        service = self._service(BrokenQwen())
        try:
            self._publish_state(service)
            self._publish_chat(service, "Alice", "Goblin, follow me.", "outage-chat")
            result = service.run_once()
            self.assertEqual(result.status, "qwen_failed")
            self.assertIn("intent failed", result.detail)
        finally:
            service.close()


if __name__ == "__main__":
    unittest.main()
