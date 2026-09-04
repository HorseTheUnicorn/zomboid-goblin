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
    def propose_intent(self, _context: object):
        return IntentValidator().validate(
            {
                "intent": "MOVE_TO",
                "mode": "ROAM",
                "target": {"kind": "area", "name": "home base"},
            }
        )


class BrokenQwen:
    def propose_intent(self, _context: object):
        from goblin_zomboid.qwen import QwenError

        raise QwenError("test model outage")


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

    def test_service_drives_server_npc_and_keeps_coordinates_out_of_qwen_state(self) -> None:
        service = GoblinService(
            self.config,
            memory_path=self.directory / "memory.sqlite3",
            qwen=FakeQwen(),
            clock=lambda: 2_000.0,
        )
        try:
            service.store.publish_runtime(
                "zomboid-heartbeat",
                make_message(
                    "runtime.heartbeat", timestamp_ms=2_000_000,
                    body_mode="npc", npc_id="goblin.primary",
                ),
            )
            service.store.publish_runtime(
                "zomboid-state",
                make_message(
                    "runtime.state", timestamp_ms=2_000_000,
                    alive=True, body_present=True, body_mode="npc",
                    npc_id="goblin.primary", control_ready=True,
                    npc_engine_ready=True, mode="ROAM", x=100, y=200,
                ),
            )
            result = service.run_once()
            self.assertEqual(result.status, "npc_command_published")
            self.assertNotIn("x", service.last_state)
            item = next(service.store.iter_ready("commands"))
            command = service.store.read_ready(item)
            self.assertEqual(command.type, "command.npc_action")
            self.assertEqual(command.fields["npc_id"], "goblin.primary")
        finally:
            service.close()

    def test_qwen_outage_uses_deterministic_survival_fallback(self) -> None:
        service = GoblinService(
            self.config,
            memory_path=self.directory / "memory.sqlite3",
            qwen=BrokenQwen(),
            clock=lambda: 2_000.0,
        )
        try:
            service.store.publish_runtime(
                "zomboid-state",
                make_message(
                    "runtime.state", timestamp_ms=2_000_000,
                    alive=True, body_present=True, body_mode="npc",
                    npc_id="goblin.primary", control_ready=True,
                    npc_engine_ready=True, mode="ROAM",
                    threat_level="overwhelming",
                ),
            )
            result = service.run_once()
            self.assertEqual(result.status, "fallback_command_published")
            self.assertEqual(service.last_action["action"], "FLEE")
        finally:
            service.close()


if __name__ == "__main__":
    unittest.main()
