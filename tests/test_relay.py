from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from goblin_zomboid.relay import RelayConfig, SshFileRelay, _safe_path, _safe_stem


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


class RelayTests(unittest.TestCase):
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
                )
            )
            self.assertEqual(
                relay._remote_file("commands", "req-1.json"),
                "/home/zomboid/Zomboid/Lua/goblin-bridge/commands/req-1.json",
            )
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


if __name__ == "__main__":
    unittest.main()
