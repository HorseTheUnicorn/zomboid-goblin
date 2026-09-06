from __future__ import annotations

import shutil
from pathlib import Path
import tempfile
import unittest

from goblin_zomboid.ipc import (
    AckConsumer,
    BridgeStore,
    COMMAND_ACK_STATES,
    CommandConsumer,
    EventConsumer,
    RequestLedger,
    ResponseConsumer,
)
from goblin_zomboid.protocol import ProtocolError, decode_message, make_message


class ProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = Path(tempfile.mkdtemp(prefix="goblin-bridge-"))
        self.store = BridgeStore(self.temp_dir)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def test_ready_marker_is_created_after_json(self) -> None:
        message = make_message(
            "command.intent",
            request_id="fresh-1",
            intent="WAIT",
            mode="SAFE",
        )
        json_path = self.store.publish("commands", message, stem="fresh-1")
        self.assertTrue(json_path.is_file())
        self.assertTrue(json_path.with_suffix(".ready").is_file())
        item = next(self.store.iter_ready("commands"))
        self.assertEqual(self.store.read_ready(item).request_id, "fresh-1")
        self.assertEqual(
            (self.temp_dir / "commands" / ".ready-index.json").read_text(
                encoding="utf-8"
            ),
            '["fresh-1"]',
        )

    def test_bridge_marker_is_created(self) -> None:
        marker = self.temp_dir / ".goblin-bridge-v1"
        self.assertEqual(marker.read_text(encoding="utf-8"), "goblin-bridge-v1\n")

    def test_runtime_is_replaced_atomically(self) -> None:
        self.store.publish_runtime(
            "zomboid-heartbeat",
            make_message("runtime.heartbeat", request_id="heartbeat-1", status="online"),
        )
        self.store.publish_runtime(
            "zomboid-heartbeat",
            make_message("runtime.heartbeat", request_id="heartbeat-2", status="disabled"),
        )
        result = self.store.read_runtime("zomboid-heartbeat")
        self.assertEqual(result.request_id, "heartbeat-2")
        self.assertFalse(
            any(path.name.startswith(".") for path in (self.temp_dir / "runtime").iterdir())
        )

    def test_malformed_message_is_deadlettered(self) -> None:
        commands = self.temp_dir / "commands"
        (commands / "bad-1.json").write_text("{not json", encoding="utf-8")
        (commands / "bad-1.ready").write_text("", encoding="utf-8")
        consumer = CommandConsumer(
            self.store, RequestLedger(self.temp_dir / "ledger.json")
        )
        self.assertEqual(consumer.poll(), [])
        self.assertTrue((self.temp_dir / "deadletter" / "bad-1.json").is_file())
        self.assertTrue((self.temp_dir / "deadletter" / "bad-1.ready").is_file())

    def test_oversized_message_is_rejected(self) -> None:
        small_root = self.temp_dir / "small"
        small_root.mkdir()
        small_store = BridgeStore(small_root, max_message_bytes=256)
        with self.assertRaises(ProtocolError):
            small_store.publish(
                "commands",
                make_message(
                    "command.intent",
                    request_id="large-1",
                    payload="x" * 1000,
                ),
                stem="large-1",
            )

    def test_stale_and_duplicate_commands_are_not_executed(self) -> None:
        now = 2_000_000
        self.store.publish(
            "commands",
            make_message(
                "command.intent",
                request_id="fresh-1",
                timestamp_ms=now,
                intent="WAIT",
            ),
            stem="fresh-1",
        )
        self.store.publish(
            "commands",
            make_message(
                "command.intent",
                request_id="stale-1",
                timestamp_ms=now - 10_000,
                intent="WAIT",
            ),
            stem="stale-1",
        )
        consumer = CommandConsumer(
            self.store,
            RequestLedger(self.temp_dir / "ledger.json"),
            max_age_ms=1_000,
        )
        commands = consumer.poll(now=now)
        self.assertEqual([item.message.request_id for item in commands], ["fresh-1"])
        consumer.finalize(commands[0], status="accepted", detail="safe")
        self.assertTrue((self.temp_dir / "archive" / "fresh-1.json").is_file())
        self.assertTrue((self.temp_dir / "acks" / "fresh-1.json").is_file())
        self.assertTrue((self.temp_dir / "responses" / "fresh-1.json").is_file())
        self.assertTrue((self.temp_dir / "deadletter" / "stale-1.json").is_file())

        self.store.publish(
            "commands",
            make_message(
                "command.intent",
                request_id="fresh-1",
                timestamp_ms=now,
                intent="WAIT",
            ),
            stem="fresh-1",
        )
        self.assertEqual(consumer.poll(now=now), [])
        self.assertTrue((self.temp_dir / "archive" / "fresh-1.json").is_file())

    def test_decode_rejects_mixed_payload_and_direct_fields(self) -> None:
        with self.assertRaises(ProtocolError):
            decode_message(
                b'{"protocol":1,"request_id":"a-1","timestamp_ms":1,"type":"x","payload":{},"status":"online"}'
            )

    def test_events_are_consumed_once_and_malformed_events_are_deadlettered(self) -> None:
        now = 2_000_000
        self.store.publish(
            "events",
            make_message(
                "event.chat",
                request_id="event-1",
                timestamp_ms=now,
                speaker="Alice",
                text="Has anyone seen Goblin?",
            ),
            stem="event-1",
        )
        self.store.publish(
            "events",
            make_message(
                "event.unknown",
                request_id="event-2",
                timestamp_ms=now,
            ),
            stem="event-2",
        )
        consumer = EventConsumer(
            self.store,
            RequestLedger(self.temp_dir / "event-ledger.json"),
            max_age_ms=1_000,
        )
        events = consumer.poll(now=now)
        self.assertEqual([event.message.request_id for event in events], ["event-1"])
        consumer.finalize(events[0])
        self.assertTrue((self.temp_dir / "archive" / "event-1.json").is_file())
        self.assertTrue((self.temp_dir / "deadletter" / "event-2.json").is_file())

        self.store.publish(
            "events",
            make_message(
                "event.chat",
                request_id="event-1",
                timestamp_ms=now,
                speaker="Alice",
                text="Has anyone seen Goblin?",
            ),
            stem="event-1-replay",
        )
        self.assertEqual(consumer.poll(now=now), [])
        self.assertTrue(
            any(path.name.startswith("event-1-replay") for path in (self.temp_dir / "archive").glob("*.json"))
        )

    def test_response_consumer_accepts_only_bounded_command_results(self) -> None:
        now = 2_000_000
        self.store.publish(
            "responses",
            make_message(
                "response.command",
                request_id="intent-1",
                timestamp_ms=now,
                status="accepted",
                detail="typed action sent",
            ),
            stem="intent-1",
        )
        consumer = ResponseConsumer(
            self.store,
            RequestLedger(self.temp_dir / "response-ledger.json"),
            max_age_ms=1_000,
        )
        responses = consumer.poll(now=now)
        self.assertEqual(len(responses), 1)
        self.assertEqual(responses[0].message.fields["status"], "accepted")
        consumer.finalize(responses[0])
        self.assertTrue((self.temp_dir / "archive" / "intent-1.json").is_file())

    def test_ack_lifecycle_is_immutable_and_linked_to_command(self) -> None:
        self.store.acknowledge(
            "command-1", status="accepted", detail="admitted", terminal=False
        )
        self.store.acknowledge(
            "command-1", status="RUNNING", detail="moving", terminal=False
        )
        self.store.acknowledge(
            "command-1", status="SUCCESS", detail="arrived", terminal=True
        )

        items = list(self.store.iter_ready("acks"))
        self.assertEqual(len(items), 3)
        messages = [self.store.read_ready(item) for item in items]
        self.assertEqual(
            {message.fields["status"] for message in messages},
            {"ACCEPTED", "RUNNING", "SUCCESS"},
        )
        self.assertTrue(all(message.fields["command_id"] == "command-1" for message in messages))
        self.assertTrue((self.temp_dir / "acks" / "command-1.json").is_file())
        self.assertEqual(
            len({message.request_id for message in messages}), 3,
        )
        self.assertEqual(COMMAND_ACK_STATES, {
            "ACCEPTED", "RUNNING", "SUCCESS", "FAILED", "REJECTED", "TIMEOUT"
        })

        consumer = AckConsumer(
            self.store,
            RequestLedger(self.temp_dir / "ack-ledger.json"),
        )
        acknowledgements = consumer.poll()
        self.assertEqual(len(acknowledgements), 3)
        self.assertEqual(
            {ack.message.fields["status"] for ack in acknowledgements},
            {"ACCEPTED", "RUNNING", "SUCCESS"},
        )
        for acknowledgement in acknowledgements:
            consumer.finalize(acknowledgement)
        self.assertEqual(list(self.store.iter_ready("acks")), [])


if __name__ == "__main__":
    unittest.main()
