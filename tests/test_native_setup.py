from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "ops"
    / "native-client"
    / "setup_steam.py"
)
SPEC = importlib.util.spec_from_file_location("goblin_setup_steam", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SETUP = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SETUP
SPEC.loader.exec_module(SETUP)


class NativeSetupTests(unittest.TestCase):
    def test_shell_quote_rejects_multiline_values(self) -> None:
        self.assertEqual(SETUP._shell_quote("plain"), "plain")
        self.assertIn("'", SETUP._shell_quote("p a's"))
        with self.assertRaises(SETUP.SetupError):
            SETUP._shell_quote("line\nvalue")

    def test_secret_redaction_is_output_safe(self) -> None:
        self.assertEqual(
            SETUP._redact("password appears", ["password"]),
            "[redacted] appears",
        )
        with self.assertRaises(SETUP.SetupError):
            SETUP._bounded_secret("line\rvalue", "test password")

    def test_prompt_scanners_ignore_old_scan_tail_matches(self) -> None:
        token = "steam>"
        tail = "status steam>"
        self.assertEqual(
            SETUP._count_new_token(tail + " update", len(tail), token),
            0,
        )
        self.assertEqual(
            SETUP._count_new_token(tail + "steam>", len(tail), token),
            1,
        )

        guard_tail = "Steam Guard co"
        self.assertEqual(
            SETUP._count_new_matches(
                SETUP._GUARD_PROMPT_RE,
                guard_tail + "de:",
                len(guard_tail),
            ),
            1,
        )
        self.assertEqual(
            SETUP._count_new_matches(
                SETUP._GUARD_PROMPT_RE,
                "Steam Guard code: update",
                len("Steam Guard code: "),
            ),
            0,
        )

    def test_server_defaults_validate_without_network_access(self) -> None:
        self.assertEqual(SETUP._validate_host("192.168.0.3"), "192.168.0.3")
        self.assertEqual(SETUP._validate_port("16261"), 16261)
        self.assertEqual(SETUP._validate_username("Goblin"), "Goblin")
        with self.assertRaises(SETUP.SetupError):
            SETUP._validate_port("70000")

    def test_client_root_must_be_below_service_home(self) -> None:
        temp_dir = Path(__file__).resolve().parent
        account = SETUP.ServiceAccount(
            name="goblin",
            uid=1001,
            gid=1001,
            home=temp_dir,
            shell="/bin/bash",
        )
        self.assertEqual(
            SETUP._resolve_client_root(temp_dir / "client", account),
            temp_dir / "client",
        )
        with self.assertRaises(SETUP.SetupError):
            SETUP._resolve_client_root(Path(temp_dir.anchor) / "outside", account)

    def test_required_client_files_accept_steam_install_dir_layout(self) -> None:
        with TemporaryDirectory() as directory:
            client_root = Path(directory)
            install_root = client_root / "projectzomboid"
            (install_root / "natives").mkdir(parents=True)
            required = (
                install_root / "ProjectZomboid64",
                install_root / "ProjectZomboid64.json",
                install_root / "projectzomboid.jar",
                install_root / "pzexe.jar",
                install_root / "jre64" / "bin" / "java",
                install_root / "natives" / "libZNetNoSteam64.so",
                install_root / "natives" / "libsteam_api.so",
            )
            for path in required:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            self.assertEqual(SETUP._required_client_files(client_root), required)

    def test_incomplete_steam_install_is_rejected_before_credentials(self) -> None:
        with TemporaryDirectory() as directory:
            client_root = Path(directory)
            install_root = client_root / "projectzomboid"
            (install_root / "natives").mkdir(parents=True)
            for path in (
                install_root / "ProjectZomboid64",
                install_root / "ProjectZomboid64.json",
                install_root / "projectzomboid.jar",
                install_root / "natives" / "libZNetNoSteam64.so",
            ):
                path.touch()
            with self.assertRaises(SETUP.SetupError):
                SETUP._verify_native_client(client_root)


if __name__ == "__main__":
    unittest.main()
