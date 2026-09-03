from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory
import unittest


NATIVE_CLIENT = Path(__file__).resolve().parents[1] / "ops" / "native-client"
if str(NATIVE_CLIENT) not in sys.path:
    sys.path.insert(0, str(NATIVE_CLIENT))

SCRIPT = NATIVE_CLIENT / "publish_workshop.py"
SPEC = importlib.util.spec_from_file_location("goblin_publish_workshop", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PUBLISH = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PUBLISH
SPEC.loader.exec_module(PUBLISH)


class WorkshopPublishTests(unittest.TestCase):
    def test_descriptor_accepts_pz_metadata_and_repeated_descriptions(self) -> None:
        with TemporaryDirectory(prefix="goblin-workshop-") as directory:
            descriptor = Path(directory) / "workshop.txt"
            descriptor.write_text(
                "\n".join(
                    (
                        "version=1",
                        "id=1234567890",
                        "title=GoblinSurvivor",
                        "description=First line",
                        "description=Second line",
                        "tags=Build 42;Multiplayer",
                        "visibility=unlisted",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            metadata = PUBLISH._read_workshop_metadata(descriptor)
            self.assertEqual(metadata.title, "GoblinSurvivor")
            self.assertEqual(metadata.description, "First line\nSecond line")
            self.assertEqual(metadata.visibility, "unlisted")

    def test_vdf_uses_unlisted_visibility_and_escapes_values(self) -> None:
        metadata = PUBLISH.WorkshopMetadata(
            title='Goblin "Survivor"',
            description="line one\nline two",
            tags="Build 42;Multiplayer",
            visibility="unlisted",
        )
        vdf = PUBLISH._build_vdf(
            content_folder=Path("/home/goblin/Goblin Mod"),
            metadata=metadata,
            published_file_id="0",
            visibility="unlisted",
            change_note="Initial release",
            preview_file=None,
        )
        self.assertIn('"appid" "108600"', vdf)
        self.assertIn('"publishedfileid" "0"', vdf)
        self.assertIn('"visibility" "3"', vdf)
        self.assertIn('Goblin \\"Survivor\\"', vdf)
        self.assertIn('line one\\nline two', vdf)

    def test_content_validation_requires_goblin_mod_and_rejects_secret_names(self) -> None:
        with TemporaryDirectory(prefix="goblin-workshop-") as directory:
            content = Path(directory)
            (content / "Contents" / "mods" / "GoblinSurvivor" / "42").mkdir(parents=True)
            (content / "workshop.txt").write_text(
                "version=1\ntitle=GoblinSurvivor\ndescription=bridge\nvisibility=unlisted\n",
                encoding="utf-8",
            )
            (content / "Contents" / "mods" / "GoblinSurvivor" / "42" / "mod.info").write_text(
                "id=GoblinSurvivor\n",
                encoding="utf-8",
            )
            descriptor, metadata = PUBLISH._validate_content(content)
            self.assertEqual(descriptor.name, "workshop.txt")
            self.assertEqual(metadata.title, "GoblinSurvivor")

            (content / ".env").write_text("SECRET=not-for-workshop\n", encoding="utf-8")
            with self.assertRaises(PUBLISH.SetupError):
                PUBLISH._validate_content(content)

    def test_upload_payload_flattens_contents_mods_to_root_mods(self) -> None:
        with TemporaryDirectory(prefix="goblin-workshop-") as directory:
            repo_root = Path(directory)
            content = repo_root / "mod"
            mod = content / "Contents" / "mods" / "GoblinSurvivor" / "42"
            mod.mkdir(parents=True)
            (content / "workshop.txt").write_text(
                "version=1\ntitle=GoblinSurvivor\ndescription=bridge\nvisibility=unlisted\n",
                encoding="utf-8",
            )
            (mod / "mod.info").write_text("id=GoblinSurvivor\n", encoding="utf-8")

            upload = PUBLISH._prepare_upload_content(content, repo_root)
            try:
                self.assertTrue((upload / "mods" / "GoblinSurvivor" / "42" / "mod.info").is_file())
                self.assertFalse((upload / "Contents").exists())
                self.assertTrue((upload / "workshop.txt").is_file())
            finally:
                shutil.rmtree(upload, ignore_errors=True)

    def test_existing_vdf_id_is_read_but_missing_id_creates_new_item(self) -> None:
        with TemporaryDirectory(prefix="goblin-workshop-") as directory:
            path = Path(directory) / "item.vdf"
            self.assertEqual(PUBLISH._existing_published_file_id(path), "0")
            path.write_text(
                '"workshopitem" { "publishedfileid" "9876543210" }\n',
                encoding="utf-8",
            )
            self.assertEqual(PUBLISH._existing_published_file_id(path), "9876543210")


if __name__ == "__main__":
    unittest.main()
