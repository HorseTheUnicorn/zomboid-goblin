import tempfile
import unittest
from pathlib import Path

from tools.pz_inventory_fingerprint import selected_config, tree_fingerprint


class InstalledFingerprintTests(unittest.TestCase):
    def test_secret_fields_are_not_returned(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "server.ini"
            path.write_text("Mods=GoblinSurvivor\nWorkshopItems=123\nRCONPassword=secret\nPassword=secret\nPauseEmpty=true\n")
            self.assertEqual(selected_config(path), {
                "Mods": "GoblinSurvivor", "WorkshopItems": "123", "PauseEmpty": "true",
            })

    def test_duplicate_relevant_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "server.ini"
            path.write_text("Mods=A\nMods=B\nWorkshopItems=123\n")
            with self.assertRaises(ValueError):
                selected_config(path)

    def test_tree_hash_tracks_content_and_paths_not_mtime(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            item = root / "item.txt"
            item.write_text("one")
            first = tree_fingerprint(root)
            item.touch()
            self.assertEqual(first, tree_fingerprint(root))
            item.write_text("two")
            second = tree_fingerprint(root)
            self.assertNotEqual(first["sha256"], second["sha256"])
            item.rename(root / "renamed.txt")
            self.assertNotEqual(second["sha256"], tree_fingerprint(root)["sha256"])

    def test_missing_root_is_not_empty_success(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                tree_fingerprint(Path(folder) / "missing")

    def test_empty_root_is_not_valid_provenance(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                tree_fingerprint(Path(folder))


if __name__ == "__main__":
    unittest.main()
