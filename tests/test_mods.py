from __future__ import annotations

import hashlib
from pathlib import Path
import tempfile
import unittest

from goblin_zomboid.mods import (
    ModManifest,
    ModParityError,
    ModParityValidator,
    encode_manifest,
    hash_tree,
)


MANIFEST = {
    "game_build": "42.20.4 b0bbce05d5",
    "mods": ["Run and Reload", "GoblinSurvivor"],
    "workshop_items": ["1234567890", "9876543210"],
    "goblin_survivor_sha256": "a" * 64,
}


class ModManifestTests(unittest.TestCase):
    def test_exact_ordered_server_and_client_manifests_verify(self) -> None:
        server = ModManifest.from_mapping(MANIFEST)
        client = ModManifest.from_mapping(dict(MANIFEST))
        result = ModParityValidator.compare(server, client)
        self.assertTrue(result.verified)
        self.assertEqual(result.status, "verified")
        self.assertEqual(encode_manifest(server), encode_manifest(client))

    def test_workshop_order_is_part_of_parity(self) -> None:
        server = ModManifest.from_mapping(MANIFEST)
        changed = dict(MANIFEST)
        changed["workshop_items"] = ["9876543210", "1234567890"]
        client = ModManifest.from_mapping(changed)
        result = ModParityValidator.compare(server, client)
        self.assertEqual(result.status, "mismatch")
        self.assertIn("WorkshopItems", " ".join(result.reasons))

    def test_missing_manifest_cannot_be_forged_by_status_field(self) -> None:
        result = ModParityValidator.from_runtime(
            {"client_mod_parity": "verified"}
        )
        self.assertEqual(result.status, "missing")
        self.assertFalse(result.verified)

    def test_control_compatibility_does_not_require_unrelated_loadout_order(self) -> None:
        server = ModManifest.from_mapping(MANIFEST)
        changed = dict(MANIFEST)
        changed["mods"] = ["GoblinSurvivor", "UnrelatedMod"]
        changed["workshop_items"] = ["9876543210"]
        client = ModManifest.from_mapping(changed)
        self.assertTrue(ModParityValidator.control_compatible(server, client))
        self.assertEqual(ModParityValidator.compare(server, client).status, "mismatch")

    def test_control_compatibility_requires_goblin_content_and_active_mod(self) -> None:
        server = ModManifest.from_mapping(MANIFEST)
        missing_mod = dict(MANIFEST)
        missing_mod["mods"] = ["Run and Reload"]
        with self.assertRaises(ModParityError):
            ModManifest.from_mapping(missing_mod)
        changed_hash = dict(MANIFEST)
        changed_hash["goblin_survivor_sha256"] = "b" * 64
        client = ModManifest.from_mapping(changed_hash)
        self.assertFalse(ModParityValidator.control_compatible(server, client))

    def test_manifest_rejects_missing_goblin_or_duplicate_ids(self) -> None:
        missing = dict(MANIFEST)
        missing["mods"] = ["CommonSense"]
        with self.assertRaises(ModParityError):
            ModManifest.from_mapping(missing)

        duplicate = dict(MANIFEST)
        duplicate["workshop_items"] = ["1234567890", "1234567890"]
        with self.assertRaises(ModParityError):
            ModManifest.from_mapping(duplicate)

    def test_hash_tree_is_stable_and_includes_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="goblin-mod-hash-") as temp:
            root = Path(temp)
            (root / "nested").mkdir()
            (root / "main.lua").write_text("return 1\n", encoding="utf-8")
            (root / "nested" / "config.ini").write_text("enabled=false\n", encoding="utf-8")
            first = hash_tree(root)
            self.assertEqual(first, hash_tree(root))
            (root / "nested" / "config.ini").write_text("enabled=true\n", encoding="utf-8")
            self.assertNotEqual(first, hash_tree(root))

    def test_hash_tree_uses_platform_neutral_relative_path_order(self) -> None:
        with tempfile.TemporaryDirectory(prefix="goblin-mod-order-") as temp:
            root = Path(temp)
            files = {
                "media/AnimSets/.keep": "anim\n",
                "media/actiongroups/.keep": "actions\n",
                "media/lua/Main.lua": "return 1\n",
            }
            for relative, contents in files.items():
                path = root / Path(relative)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")

            expected = hashlib.sha256()
            for relative in sorted(files):
                expected.update(relative.encode("utf-8"))
                expected.update(b"\0")
                expected.update((root / Path(relative)).read_bytes())
                expected.update(b"\0")
            self.assertEqual(hash_tree(root), expected.hexdigest())


if __name__ == "__main__":
    unittest.main()
