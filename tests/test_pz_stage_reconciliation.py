import copy
import tempfile
import unittest
from pathlib import Path

from tools.check_pz_catalog import canonical_hash
from tools.reconcile_pz_stage import locate, reconcile, root_record, selected_files


class StageReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.snapshot = base / "content"
        self.runtime = base / "runtime/cache/mods"
        self.source = self.snapshot / "steamapps/workshop/content/108600/123/mods/Goblin"
        self.mod = self.runtime / "Goblin"
        for root in (self.source, self.mod):
            (root / "42").mkdir(parents=True)
            (root / "42/mod.info").write_text("id=GoblinSurvivor\n", encoding="utf-8")
            (root / "42/script.txt").write_text("same content", encoding="utf-8")
            (root / "42/goblin-server.jar").write_bytes(b"captured")
        self.helper = self.mod / "42/goblin-server.jar"
        self.helper.write_bytes(b"explicit candidate")
        for root in (self.snapshot, base / "runtime/game"):
            for kind in ("scripts", "lua"):
                (root / "media" / kind).mkdir(parents=True)
                (root / "media" / kind / "fixture.txt").write_text("vanilla", encoding="utf-8")
        roots = [root_record("common", None), root_record("42", selected_files(self.mod / "42"))]
        content = [{"mod_id": "GoblinSurvivor", "roots": roots, "sha256": canonical_hash(roots)}]
        self.proof = {"enabled_mods": ["GoblinSurvivor"], "enabled_mods_content": content,
                      "enabled_mods_content_algorithm": "selected-common-version-roots-v1",
                      "enabled_mods_fingerprint": canonical_hash(content),
                      "export_timestamp": "fixture", "game_build": "fixture"}

    def run_reconcile(self, proof=None):
        return reconcile(proof or self.proof, self.snapshot, self.runtime, self.helper)

    def test_only_explicit_helper_overlay_is_accepted(self):
        report = self.run_reconcile()
        self.assertEqual(len(report["allowed_candidate_differences"]), 1)
        self.assertEqual(report["allowed_candidate_differences"][0]["path"], "42/goblin-server.jar")

    def test_changed_staging_file_invalidates_export(self):
        (self.mod / "42/script.txt").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "no longer matches"):
            self.run_reconcile()

    def test_content_matching_export_but_not_snapshot_is_rejected(self):
        (self.source / "42/script.txt").write_text("different original", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Unapproved snapshot difference"):
            self.run_reconcile()

    def test_missing_or_duplicate_mod_identity_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            locate([self.mod], "not-installed", "42")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            locate([self.mod, self.source], "GoblinSurvivor", "42")

    def test_changed_vanilla_rejected(self):
        (self.snapshot / "media/lua/fixture.txt").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Vanilla lua differs"):
            self.run_reconcile()

    def test_common_only_identity(self):
        common = self.mod / "common"
        common.mkdir()
        (common / "mod.info").write_text("id=CommonOnly\n", encoding="utf-8")
        self.assertEqual(locate([self.mod], "CommonOnly", "42.99"), self.mod)

    def test_changed_root_manifest_is_rejected(self):
        bad = copy.deepcopy(self.proof)
        bad["enabled_mods_content"][0]["roots"][1]["file_count"] += 1
        with self.assertRaises(ValueError):
            self.run_reconcile(bad)


if __name__ == "__main__":
    unittest.main()
