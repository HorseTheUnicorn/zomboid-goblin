import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import capture_milestone1_trace as trace


class Milestone1TraceTests(unittest.TestCase):
    def test_installed_fingerprint_requires_matching_module_and_jar(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mod = root / "installed"
            module = mod / "42/media/lua/server/GoblinSurvivor/GoblinWorld.lua"
            jar = mod / "42/goblin-server.jar"
            module.parent.mkdir(parents=True)
            module.write_bytes(b"current module")
            jar.write_bytes(b"current jar")
            sources = {"GoblinWorld.lua":
                       "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinWorld.lua"}
            with patch.object(trace, "CURRENT_SOURCES", sources):
                expected = trace.installed_fingerprint(mod)
                trace.verify_installed([mod], expected)
                module.write_bytes(b"stale module")
                with self.assertRaisesRegex(ValueError, "installed runtime differs"):
                    trace.verify_installed([mod], expected)
                module.write_bytes(b"current module")
                jar.write_bytes(b"stale jar")
                with self.assertRaisesRegex(ValueError, "installed runtime differs"):
                    trace.verify_installed([mod], expected)

    def test_snapshot_keeps_actor_positions_and_authority_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "exact-state.json"
            path.write_text(json.dumps({
                "timestamp_ms": 123,
                "entities": [
                    {"entity_id": "player.one", "kind": "player", "x": 1,
                     "y": 2, "z": 0, "private": "not for trace"},
                    {"entity_id": "goblin.primary.one", "kind": "goblin", "x": 2,
                     "y": 3, "z": 0, "native_owner_player": "one"},
                    {"entity_id": "zombie.other", "kind": "zombie", "x": 4},
                ],
            }), encoding="utf-8")
            sample = trace.snapshot(path)
            self.assertEqual(len(sample["entities"]), 2)
            self.assertEqual(sample["timestamp_ms"], 123)
            self.assertNotIn("private", sample["entities"][0])
            self.assertEqual(sample["entities"][1]["native_owner_player"], "one")


if __name__ == "__main__":
    unittest.main()
