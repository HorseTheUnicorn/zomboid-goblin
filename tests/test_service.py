from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest

from goblin_zomboid.character import CharacterLifecycle
from goblin_zomboid.config import AgentConfig
from goblin_zomboid.ipc import BridgeStore
from goblin_zomboid.memory import MemoryStore
from goblin_zomboid.protocol import make_message
from goblin_zomboid.service import GoblinService
from goblin_zomboid.validator import IntentValidator


class FakeQwen:
    def __init__(
        self,
        intent: dict[str, object],
        character_proposal: dict[str, object] | None = None,
        speech: str | None = None,
    ) -> None:
        self.intent = IntentValidator().validate(intent)
        self.character_proposal = character_proposal
        self.speech = speech

    def propose_intent(self, _context: dict[str, object]):
        return self.intent

    def choose_character(self, _catalog: object, _context: dict[str, object]):
        if self.character_proposal is None:
            raise AssertionError("character chooser was called unexpectedly")
        return self.character_proposal

    def propose_speech(self, _context: dict[str, object]) -> str:
        if self.speech is None:
            raise AssertionError("speech proposal was called unexpectedly")
        return self.speech


CHARACTER_CATALOG = {
    "version": "build42-test",
    "options": {
        "gender": [{"id": "male", "label": "Male", "source": "vanilla"}],
        "skin_tone": [{"id": "tone1", "label": "Tone 1", "source": "vanilla"}],
        "hair_style": [{"id": "messy", "label": "Messy", "source": "vanilla"}],
        "hair_color": [{"id": "brown", "label": "Brown", "source": "vanilla"}],
        "profession": [{"id": "unemployed", "label": "Unemployed", "source": "vanilla"}],
        "trait": [{"id": "outdoorsman", "label": "Outdoorsman", "source": "vanilla"}],
        "clothing_top": [{"id": "hoodie", "label": "Hoodie", "source": "vanilla"}],
        "accessory_hat": [{"id": "beanie", "label": "Beanie", "source": "vanilla"}],
    },
}

CHARACTER_PROPOSAL = {
    "name": "Goblin",
    "gender": "male",
    "skin_tone": "tone1",
    "hair_style": "messy",
    "hair_color": "brown",
    "profession": "unemployed",
    "traits": ["outdoorsman"],
    "clothing": {"clothing_top": "hoodie"},
    "accessories": ["beanie"],
}

MOD_MANIFEST = {
    "game_build": "42.20.4 b0bbce05d5",
    "mods": ["CommonSense", "GoblinSurvivor"],
    "workshop_items": ["1234567890"],
    "goblin_survivor_sha256": "a" * 64,
}


class ServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix="goblin-service-"))
        self.now = 1_700_000_000.0

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def config(self, enabled: bool, *, start_paused: bool = True) -> AgentConfig:
        bridge_root = self.temp_dir / "bridge"
        bridge_root.mkdir(exist_ok=True)
        return AgentConfig(
            bridge_root=bridge_root,
            enabled=enabled,
            heartbeat_seconds=5,
            pz_timeout_seconds=15,
            max_message_bytes=256 * 1024,
            pz_host="192.168.0.3",
            start_paused=start_paused,
        )

    def test_explicit_start_unpaused_setting_is_honored(self) -> None:
        service = GoblinService(
            self.config(True, start_paused=False),
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen({"intent": "WAIT", "mode": "SAFE"}),
            clock=lambda: self.now,
        )
        try:
            self.assertFalse(service.paused)
        finally:
            service.close()

    def test_events_feed_memory_and_relationships_while_service_is_paused(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish(
            "events",
            make_message(
                "event.chat",
                request_id="event-chat-1",
                timestamp_ms=timestamp,
                speaker="Alice",
                text="Goblin, hide or join our party?",
            ),
            stem="event-chat-1",
        )
        store.publish(
            "events",
            make_message(
                "event.threat_changed",
                request_id="event-threat-1",
                timestamp_ms=timestamp,
                threat_level="near",
                count_bucket="few",
            ),
            stem="event-threat-1",
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=None,
            clock=lambda: self.now,
        )
        try:
            result = service.run_once()
            self.assertEqual(result.status, "paused")
            self.assertEqual(
                [event["kind"] for event in service.last_events],
                ["chat", "threat_changed"],
            )
            self.assertEqual(service.event_overlay["threat_level"], "near")
            self.assertEqual(service.memory.relationship("Alice")["affinity"], 0.01)
            self.assertTrue(
                any(item["kind"] == "event.chat" for item in service.memory.recent_memories())
            )
            self.assertFalse(list(service.store.iter_ready("events")))
        finally:
            service.close()

    def test_event_location_payload_is_deadlettered_before_model_context(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish(
            "events",
            make_message(
                "event.chat",
                request_id="event-location-1",
                timestamp_ms=timestamp,
                speaker="Alice",
                text="x=100 y=200",
            ),
            stem="event-location-1",
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=None,
            clock=lambda: self.now,
        )
        try:
            self.assertEqual(service.run_once().status, "paused")
            self.assertEqual(service.last_events, [])
            self.assertTrue(
                (config.bridge_root / "deadletter" / "event-location-1.json").is_file()
            )
        finally:
            service.close()

    def test_addressed_chat_can_publish_only_a_validated_say_command(self) -> None:
        config = self.config(True, start_paused=False)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=True,
                client_control_ready=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                mode="SAFE",
                alive=True,
                character_state="active",
                character_generation=0,
            ),
        )
        store.publish(
            "events",
            make_message(
                "event.chat",
                request_id="event-chat-reply-1",
                timestamp_ms=timestamp,
                speaker="Alice",
                text="Goblin, hide or join our party?",
            ),
            stem="event-chat-reply-1",
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {"intent": "WAIT", "mode": "SAFE"},
                speech="I hear you. Give me a minute to decide.",
            ),
            clock=lambda: self.now,
        )
        try:
            self.assertEqual(service.run_once().status, "command_published")
            commands = [
                service.store.read_ready(item)
                for item in service.store.iter_ready("commands")
            ]
            speech = [command for command in commands if command.fields.get("intent") == "SAY"]
            self.assertEqual(len(speech), 1)
            self.assertEqual(speech[0].fields["text"], "I hear you. Give me a minute to decide.")
            self.assertEqual(speech[0].fields["controller_action"]["action"], "SAY")
        finally:
            service.close()

    def test_disabled_master_switch_never_publishes_commands(self) -> None:
        service = GoblinService(
            self.config(False),
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {
                    "intent": "MOVE_TO",
                    "mode": "ROAM",
                    "target": {"kind": "area", "name": "the edge"},
                }
            ),
            clock=lambda: self.now,
        )
        try:
            result = service.run_once()
            self.assertEqual(result.status, "disabled")
            self.assertEqual(list(service.store.iter_ready("commands")), [])
            self.assertTrue(
                (self.temp_dir / "bridge" / "runtime" / "agent-heartbeat.json").is_file()
            )
        finally:
            service.close()

    def test_enabled_service_stays_sensor_only_without_body(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        store.publish_runtime(
            "zomboid-heartbeat",
            make_message(
                "runtime.heartbeat",
                request_id="zomboid-heartbeat",
                timestamp_ms=int(self.now * 1000),
                status="online",
            ),
        )
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=int(self.now * 1000),
                body_present=False,
                mode="SAFE",
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {
                    "intent": "SAY",
                    "mode": "SAFE",
                    "text": "The bridge is awake.",
                }
            ),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "sensor_only")
            self.assertEqual(list(service.store.iter_ready("commands")), [])
        finally:
            service.close()

    def test_body_cannot_use_claimed_parity_without_manifests(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=True,
                client_mod_parity="verified",
                mode="SAFE",
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen({"intent": "WAIT", "mode": "SAFE"}),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "waiting_for_client_mod_parity")
            self.assertEqual(list(service.store.iter_ready("commands")), [])
        finally:
            service.close()

    def test_enabled_body_publishes_only_validated_high_level_intent(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        memory = MemoryStore(self.temp_dir / "memory.sqlite3")
        memory.save_character_state(
            CharacterLifecycle.ACTIVE.value,
            {"generation": 1, "appearance": CHARACTER_PROPOSAL},
            updated_at=int(self.now),
        )
        memory.close()
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-heartbeat",
            make_message(
                "runtime.heartbeat",
                request_id="zomboid-heartbeat",
                timestamp_ms=timestamp,
                status="online",
            ),
        )
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=True,
                client_control_ready=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                mode="ROAM",
                alive=True,
                character_state="active",
                character_generation=1,
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {
                    "intent": "MOVE_TO",
                    "mode": "ROAM",
                    "target": {"kind": "area", "name": "the edge"},
                }
            ),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "command_published")
            item = next(service.store.iter_ready("commands"))
            message = service.store.read_ready(item)
            self.assertEqual(message.type, "command.intent")
            self.assertEqual(message.fields["target"]["kind"], "area")
            self.assertNotIn("x", message.as_dict())
            self.assertNotIn("y", message.as_dict())
            self.assertNotIn("z", message.as_dict())
        finally:
            service.close()

    def test_existing_body_is_adopted_without_publishing_character_creation(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=True,
                client_control_ready=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                mode="SAFE",
                alive=True,
                character_state="active",
                character_generation=0,
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen({"intent": "WAIT", "mode": "SAFE"}),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "command_published")
            record = service.memory.character_record()
            self.assertEqual(record["lifecycle"], CharacterLifecycle.ACTIVE.value)
            self.assertTrue(record["manifest"]["adopted"])
            self.assertEqual(record["manifest"]["generation"], 0)
            command = service.store.read_ready(
                next(service.store.iter_ready("commands"))
            )
            self.assertEqual(command.type, "command.intent")
        finally:
            service.close()

    def test_death_requires_a_new_generation_before_control_resumes(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)

        def publish_state(**fields: object) -> None:
            store.publish_runtime(
                "zomboid-state",
                make_message(
                    "state.snapshot",
                    request_id="zomboid-state",
                    timestamp_ms=timestamp,
                    server_mod_manifest=MOD_MANIFEST,
                    client_mod_manifest=MOD_MANIFEST,
                    client_control_ready=True,
                    mode="SAFE",
                    **fields,
                ),
            )

        publish_state(
            body_present=True,
            alive=True,
            character_state="active",
            character_generation=0,
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {"intent": "WAIT", "mode": "SAFE"},
                character_proposal=CHARACTER_PROPOSAL,
            ),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            self.assertEqual(service.run_once().status, "command_published")
            self.assertEqual(
                service.memory.character_record()["lifecycle"],
                CharacterLifecycle.ACTIVE.value,
            )

            publish_state(
                body_present=False,
                alive=False,
                character_state="dead",
                character_generation=0,
            )
            death = service.run_once()
            self.assertEqual(death.status, "sensor_only")
            self.assertEqual(
                service.memory.character_record()["lifecycle"],
                CharacterLifecycle.DEAD.value,
            )
            self.assertEqual(
                [
                    service.store.read_ready(item).type
                    for item in service.store.iter_ready("commands")
                ].count("command.character_create"),
                0,
            )

            publish_state(
                body_present=False,
                alive=False,
                character_state="recreate_required",
                character_generation=0,
                character_catalog=CHARACTER_CATALOG,
            )
            recreation = service.run_once()
            self.assertEqual(recreation.status, "character_command_published")
            self.assertEqual(
                service.memory.character_record()["lifecycle"],
                CharacterLifecycle.CREATION_PENDING.value,
            )
            command_types = [
                service.store.read_ready(item).type
                for item in service.store.iter_ready("commands")
            ]
            self.assertEqual(command_types.count("command.character_create"), 1)
            character_command = next(
                service.store.read_ready(item)
                for item in service.store.iter_ready("commands")
                if service.store.read_ready(item).type == "command.character_create"
            )
            self.assertEqual(character_command.fields["generation"], 1)

            # A stale active packet for generation 0 cannot resurrect the dead
            # body or satisfy the pending generation 1 creation.
            publish_state(
                body_present=True,
                alive=True,
                character_state="active",
                character_generation=0,
            )
            stale = service.run_once()
            self.assertEqual(stale.status, "character_state_mismatch")
            self.assertEqual(
                service.memory.character_record()["lifecycle"],
                CharacterLifecycle.CREATION_PENDING.value,
            )

            publish_state(
                body_present=True,
                alive=True,
                character_state="active",
                character_generation=1,
            )
            confirmed = service.run_once()
            self.assertEqual(confirmed.status, "command_published")
            self.assertEqual(
                service.memory.character_record()["lifecycle"],
                CharacterLifecycle.ACTIVE.value,
            )
            self.assertEqual(
                service.memory.character_record()["manifest"]["generation"],
                1,
            )
        finally:
            service.close()

    def test_persisted_recreation_requests_vanilla_screen_before_new_generation(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=True,
                alive=True,
                character_state="active",
                character_generation=0,
                client_control_ready=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                mode="SAFE",
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {"intent": "WAIT", "mode": "SAFE"},
                character_proposal=CHARACTER_PROPOSAL,
            ),
            clock=lambda: self.now,
        )
        try:
            service.memory.save_character_state(
                CharacterLifecycle.RECREATE_REQUIRED.value,
                {"generation": 0, "adopted": True},
                updated_at=int(self.now),
            )
            service.close()
            service = GoblinService(
                config,
                memory_path=self.temp_dir / "memory.sqlite3",
                qwen=FakeQwen(
                    {"intent": "WAIT", "mode": "SAFE"},
                    character_proposal=CHARACTER_PROPOSAL,
                ),
                clock=lambda: self.now,
            )
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "character_recreation_requested")
            commands = list(service.store.iter_ready("commands"))
            self.assertEqual(len(commands), 1)
            command = service.store.read_ready(commands[0])
            self.assertEqual(command.type, "command.character_recreate")
            self.assertEqual(
                service.memory.character_record()["lifecycle"],
                CharacterLifecycle.RECREATE_REQUIRED.value,
            )
        finally:
            service.close()

    def test_recreation_without_catalog_requests_native_default(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=False,
                alive=False,
                character_state="recreate_required",
                character_generation=0,
                client_control_ready=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                mode="SAFE",
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen({"intent": "WAIT", "mode": "SAFE"}),
            clock=lambda: self.now,
        )
        service.memory.save_character_state(
            CharacterLifecycle.RECREATE_REQUIRED.value,
            {"generation": 0, "adopted": True},
            updated_at=int(self.now),
        )
        service.close()
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen({"intent": "WAIT", "mode": "SAFE"}),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "character_recreation_requested")
            command = service.store.read_ready(next(service.store.iter_ready("commands")))
            self.assertEqual(command.type, "command.character_recreate")
            self.assertEqual(command.fields["generation"], 1)

            store.publish_runtime(
                "zomboid-state",
                make_message(
                    "state.snapshot",
                    request_id="zomboid-state",
                    timestamp_ms=timestamp,
                    body_present=True,
                    alive=True,
                    character_state="active",
                    character_generation=1,
                    client_control_ready=True,
                    server_mod_manifest=MOD_MANIFEST,
                    client_mod_manifest=MOD_MANIFEST,
                    mode="SAFE",
                ),
            )
            confirmed = service.run_once()
            self.assertEqual(confirmed.status, "command_published")
            record = service.memory.character_record()
            self.assertEqual(record["lifecycle"], CharacterLifecycle.ACTIVE.value)
            self.assertEqual(record["manifest"]["generation"], 1)
            self.assertEqual(record["manifest"]["creation_mode"], "vanilla_default")
        finally:
            service.close()

    def test_fresh_client_gate_gets_one_vanilla_character_command(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-heartbeat",
            make_message(
                "runtime.heartbeat",
                request_id="zomboid-heartbeat",
                timestamp_ms=timestamp,
                status="online",
            ),
        )
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=False,
                client_control_ready=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                mode="SAFE",
                alive=True,
                character_state="fresh",
                character_catalog=CHARACTER_CATALOG,
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {"intent": "WAIT", "mode": "SAFE"},
                character_proposal=CHARACTER_PROPOSAL,
            ),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "character_command_published")
            item = next(service.store.iter_ready("commands"))
            message = service.store.read_ready(item)
            self.assertEqual(message.type, "command.character_create")
            self.assertEqual(message.fields["generation"], 1)
            self.assertEqual(message.fields["proposal"]["name"], "Goblin")
            self.assertEqual(
                service.memory.character_record()["lifecycle"],
                CharacterLifecycle.CREATION_PENDING.value,
            )
        finally:
            service.close()

    def test_fresh_client_catalog_can_be_reassembled_from_runtime_chunks(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        epoch = "epoch-1"
        store.publish_runtime(
            "zomboid-catalog-meta",
            make_message(
                "state.catalog_meta",
                request_id="zomboid-catalog-meta",
                timestamp_ms=timestamp,
                status="ready",
                catalog_version=CHARACTER_CATALOG["version"],
                catalog_epoch=epoch,
                chunk_count=2,
            ),
        )
        categories = CHARACTER_CATALOG["options"]
        store.publish_runtime(
            "zomboid-catalog-0001",
            make_message(
                "state.catalog_chunk",
                request_id="zomboid-catalog-0001",
                timestamp_ms=timestamp,
                catalog_version=CHARACTER_CATALOG["version"],
                catalog_epoch=epoch,
                chunk_index=1,
                chunk_count=2,
                options={
                    "gender": categories["gender"],
                    "skin_tone": categories["skin_tone"],
                },
            ),
        )
        store.publish_runtime(
            "zomboid-catalog-0002",
            make_message(
                "state.catalog_chunk",
                request_id="zomboid-catalog-0002",
                timestamp_ms=timestamp,
                catalog_version=CHARACTER_CATALOG["version"],
                catalog_epoch=epoch,
                chunk_index=2,
                chunk_count=2,
                options={
                    key: value
                    for key, value in categories.items()
                    if key not in {"gender", "skin_tone"}
                },
            ),
        )
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=False,
                client_control_ready=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                client_catalog_version=CHARACTER_CATALOG["version"],
                mode="SAFE",
                alive=True,
                character_state="fresh",
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {"intent": "WAIT", "mode": "SAFE"},
                character_proposal=CHARACTER_PROPOSAL,
            ),
            clock=lambda: self.now,
        )
        try:
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "character_command_published")
            command = service.store.read_ready(
                next(service.store.iter_ready("commands"))
            )
            self.assertEqual(command.fields["proposal"]["name"], "Goblin")
        finally:
            service.close()

    def test_corrupt_character_manifest_never_triggers_recreation(self) -> None:
        config = self.config(True)
        store = BridgeStore(config.bridge_root)
        timestamp = int(self.now * 1000)
        store.publish_runtime(
            "zomboid-state",
            make_message(
                "state.snapshot",
                request_id="zomboid-state",
                timestamp_ms=timestamp,
                body_present=True,
                server_mod_manifest=MOD_MANIFEST,
                client_mod_manifest=MOD_MANIFEST,
                client_control_ready=True,
                mode="SAFE",
                alive=True,
                character_state="fresh",
                character_catalog=CHARACTER_CATALOG,
            ),
        )
        service = GoblinService(
            config,
            memory_path=self.temp_dir / "memory.sqlite3",
            qwen=FakeQwen(
                {"intent": "WAIT", "mode": "SAFE"},
                character_proposal=CHARACTER_PROPOSAL,
            ),
            clock=lambda: self.now,
        )
        try:
            service.memory.connection.execute(
                "INSERT INTO character_state(id, lifecycle, manifest_json, updated_at) VALUES (1, ?, ?, ?)",
                (CharacterLifecycle.FRESH.value, "not-json", int(self.now)),
            )
            service.close()
            service = GoblinService(
                config,
                memory_path=self.temp_dir / "memory.sqlite3",
                qwen=FakeQwen(
                    {"intent": "WAIT", "mode": "SAFE"},
                    character_proposal=CHARACTER_PROPOSAL,
                ),
                clock=lambda: self.now,
            )
            service.paused = False
            result = service.run_once()
            self.assertEqual(result.status, "character_storage_error")
            self.assertEqual(list(service.store.iter_ready("commands")), [])
        finally:
            service.close()


if __name__ == "__main__":
    unittest.main()
