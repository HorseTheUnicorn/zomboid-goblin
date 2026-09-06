from __future__ import annotations

from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

from goblin_zomboid.ipc import BridgeStore
from goblin_zomboid.protocol import make_message
from goblin_zomboid.relay import (
    RelayConfig,
    SshFileRelay,
    _MAX_AGENT_QUEUE_PER_PASS,
    _MAX_AGENT_RESULTS_PER_PASS,
    _MAX_EVENTS_PER_PASS,
    _safe_path,
    _safe_stem,
)


class StubRunner:
    def __init__(self, *, index: str = '["req-1"]') -> None:
        self.index = index
        self.calls: list[list[str]] = []

    def __call__(self, argv: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        self.calls.append(argv)
        command = argv[-1]
        if argv[0] == "ssh" and command.startswith("test -f"):
            return subprocess.CompletedProcess(argv, 0, "", "")
        if argv[0] == "ssh" and command.startswith("cat --"):
            return subprocess.CompletedProcess(argv, 0, self.index, "")
        return subprocess.CompletedProcess(argv, 1, "", "")


class RemoteNamesRunner(StubRunner):
    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        command = argv[-1]
        if argv[0] == "ssh" and command.startswith("find "):
            return subprocess.CompletedProcess(argv, 0, "req-1.ready\n", "")
        return super().__call__(argv, **kwargs)


class PublishRunner(StubRunner):
    def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        if argv[0] == "scp":
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")
        if argv[0] == "ssh":
            command = argv[-1]
            if (
                command.startswith("mkdir --")
                or command.startswith("mv --")
                or command.startswith("rm -f --")
                or command.startswith("rmdir --")
                or command.startswith("test -f")
            ):
                self.calls.append(argv)
                return subprocess.CompletedProcess(argv, 0, "", "")
        return super().__call__(argv, **kwargs)


class RelayTests(unittest.TestCase):
    def test_event_pass_is_bounded_so_runtime_state_has_priority(self) -> None:
        self.assertGreater(_MAX_EVENTS_PER_PASS, 0)
        self.assertLess(_MAX_EVENTS_PER_PASS, 256)
        self.assertGreater(_MAX_AGENT_QUEUE_PER_PASS, 0)
        self.assertLess(_MAX_AGENT_QUEUE_PER_PASS, 256)
        self.assertGreater(_MAX_AGENT_RESULTS_PER_PASS, 0)
        self.assertLess(_MAX_AGENT_RESULTS_PER_PASS, 256)

    def test_reverse_relay_pushes_live_state_before_pulling_remote_queue(self) -> None:
        relay = object.__new__(SshFileRelay)
        relay.config = RelayConfig(remote_role="agent")
        order: list[str] = []
        relay.push = Mock(  # type: ignore[method-assign]
            side_effect=lambda: (order.append("push") or 3)
        )
        relay.pull = Mock(  # type: ignore[method-assign]
            side_effect=lambda: (order.append("pull") or 4)
        )

        self.assertEqual(relay.run_once(), {"pulled": 4, "pushed": 3})
        self.assertEqual(order, ["push", "pull"])

    def test_path_and_stem_guards_are_fail_closed(self) -> None:
        self.assertTrue(_safe_path("/var/lib/goblin-zomboid"))
        self.assertFalse(_safe_path("var/lib/goblin-zomboid"))
        self.assertFalse(_safe_path("/var/lib/../etc"))
        self.assertTrue(_safe_stem("character-123"))
        self.assertFalse(_safe_stem("../character"))
        self.assertFalse(_safe_stem(""))

    def test_relay_requires_a_preprovisioned_local_root(self) -> None:
        temp_dir = Path(tempfile.mkdtemp(prefix="goblin-relay-"))
        try:
            with self.assertRaises(FileNotFoundError):
                SshFileRelay(RelayConfig(local_root=temp_dir / "missing"))
            temp_dir.mkdir(exist_ok=True)
            relay = SshFileRelay(
                RelayConfig(
                    local_root=temp_dir,
                    remote_root="/home/zomboid/Zomboid/Lua/goblin-bridge",
                    ssh_port=2222,
                )
            )
            self.assertEqual(
                relay._remote_file("commands", "req-1.json"),
                "/home/zomboid/Zomboid/Lua/goblin-bridge/commands/req-1.json",
            )
            self.assertEqual(relay._options()[2:4], ["-p", "2222"])
            self.assertEqual(relay._options(scp=True)[2:4], ["-P", "2222"])
            with self.assertRaises(ValueError):
                relay._remote_file("commands", "relaytmp-../bad")
            with self.assertRaises(ValueError):
                RelayConfig(local_root=temp_dir, remote_root="relative/path")
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_remote_command_index_requires_bridge_and_safe_stems(self) -> None:
        temp_dir = Path(tempfile.mkdtemp(prefix="goblin-relay-"))
        try:
            runner = StubRunner()
            relay = SshFileRelay(
                RelayConfig(local_root=temp_dir),
                runner=runner,
            )
            self.assertTrue(relay._load_remote_command_index())
            self.assertEqual(relay._remote_command_stems, ["req-1"])
            self.assertTrue(any("test -f" in call[-1] for call in runner.calls))

            invalid_runner = StubRunner(index='["../unsafe"]')
            (temp_dir / "invalid").mkdir()
            invalid_relay = SshFileRelay(
                RelayConfig(local_root=temp_dir / "invalid"),
                runner=invalid_runner,
            )
            self.assertFalse(invalid_relay._load_remote_command_index())
            self.assertIsNone(invalid_relay._remote_command_stems)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_reverse_relay_reads_remote_commands(self) -> None:
        temp_dir = Path(tempfile.mkdtemp(prefix="goblin-relay-commands-"))
        try:
            relay = SshFileRelay(
                RelayConfig(local_root=temp_dir, remote_role="agent"),
                runner=RemoteNamesRunner(),
            )
            self.assertEqual(relay._remote_names("commands", ".ready"), ["req-1.ready"])
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_message_publish_batches_json_and_ready_files(self) -> None:
        temp_dir = Path(tempfile.mkdtemp(prefix="goblin-relay-publish-"))
        try:
            store = BridgeStore(temp_dir)
            message = make_message(
                "event.chat", speaker="horse", text="goblin?",
                authorized=False,
            )
            store.publish("events", message)
            relay = SshFileRelay(
                RelayConfig(local_root=temp_dir, remote_role="agent"),
                runner=PublishRunner(),
            )

            self.assertTrue(relay._publish_remote("events", message.request_id))
            scp_calls = [call for call in relay.runner.calls if call[0] == "scp"]
            self.assertEqual(len(scp_calls), 1)
            self.assertIn(
                str(temp_dir / "events" / f"{message.request_id}.json"),
                scp_calls[0],
            )
            self.assertIn(
                str(temp_dir / "events" / f"{message.request_id}.ready"),
                scp_calls[0],
            )
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_remote_names_can_parse_newest_first_listing(self) -> None:
        class NewestRunner(RemoteNamesRunner):
            def __call__(self, argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                command = argv[-1]
                if argv[0] == "ssh" and command.startswith("find "):
                    return subprocess.CompletedProcess(
                        argv, 0, "12.0 req-znew.ready\n11.0 req-aold.ready\n", ""
                    )
                return super().__call__(argv, **kwargs)

        temp_dir = Path(tempfile.mkdtemp(prefix="goblin-relay-newest-"))
        try:
            relay = SshFileRelay(
                RelayConfig(local_root=temp_dir, remote_role="agent"),
                runner=NewestRunner(),
            )
            self.assertEqual(
                relay._remote_names("commands", ".ready", newest=True),
                ["req-znew.ready", "req-aold.ready"],
            )
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_reverse_local_relay_gates_pz_json_and_refreshes_command_index(self) -> None:
        temp_dir = Path(tempfile.mkdtemp(prefix="goblin-relay-reverse-"))
        try:
            store = BridgeStore(temp_dir)
            event = make_message(
                "event.chat", speaker="horse", text="goblin?",
                authorized=False,
            )
            event_path = store.publish("events", event, ready=False)
            relay = SshFileRelay(
                RelayConfig(local_root=temp_dir, remote_role="agent")
            )
            self.assertEqual(relay._prepare_local_json_fallback("events"), 1)
            self.assertTrue(event_path.with_suffix(".ready").is_file())

            command = make_message(
                "command.npc_action", npc_id="goblin.primary", action="HOLD"
            )
            store.publish("commands", command)
            relay._refresh_local_command_index()
            index = json.loads(
                (temp_dir / "commands" / ".ready-index.json").read_text()
            )
            self.assertIn(command.request_id, index)
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    def test_relay_rejects_unknown_remote_role(self) -> None:
        with self.assertRaises(ValueError):
            RelayConfig(remote_role="unknown")

    def test_relay_rejects_invalid_ssh_port(self) -> None:
        with self.assertRaises(ValueError):
            RelayConfig(ssh_port=0)
        with self.assertRaises(ValueError):
            RelayConfig(ssh_port=65536)


if __name__ == "__main__":
    unittest.main()
