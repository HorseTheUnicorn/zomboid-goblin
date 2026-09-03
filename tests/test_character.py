from __future__ import annotations

from pathlib import Path
import shutil
import tempfile
import unittest

from goblin_zomboid.character import (
    CharacterCreationController,
    CharacterError,
    CharacterLifecycle,
    CharacterProposalValidator,
    VanillaCatalog,
)
from goblin_zomboid.memory import MemoryStore


def test_catalog() -> VanillaCatalog:
    options = {
        "gender": [{"id": "male", "label": "Male", "source": "vanilla"}],
        "skin_tone": [{"id": "tone1", "label": "Tone 1", "source": "vanilla"}],
        "hair_style": [{"id": "messy", "label": "Messy", "source": "vanilla"}],
        "hair_color": [{"id": "brown", "label": "Brown", "source": "vanilla"}],
        "beard_style": [{"id": "scruffy", "label": "Scruffy", "source": "vanilla"}],
        "beard_color": [{"id": "brown", "label": "Brown", "source": "vanilla"}],
        "profession": [{"id": "unemployed", "label": "Unemployed", "source": "vanilla"}],
        "trait": [
            {"id": "thick_skinned", "label": "Thick Skinned", "source": "vanilla"},
            {"id": "outdoorsman", "label": "Outdoorsman", "source": "vanilla"},
        ],
        "body_type": [{"id": "average", "label": "Average", "source": "vanilla"}],
        "clothing_top": [{"id": "hoodie", "label": "Hoodie", "source": "vanilla"}],
        "clothing_bottom": [{"id": "jeans", "label": "Jeans", "source": "vanilla"}],
        "accessory_hat": [{"id": "beanie", "label": "Beanie", "source": "vanilla"}],
        "cosmetic_face": [{"id": "warpaint", "label": "War Paint", "source": "vanilla"}],
    }
    return VanillaCatalog.from_mapping({"version": "build42-test", "options": options})


def proposal() -> dict[str, object]:
    return {
        "name": "Goblin",
        "gender": "male",
        "skin_tone": "tone1",
        "hair_style": "messy",
        "hair_color": "brown",
        "beard_style": "scruffy",
        "beard_color": "brown",
        "profession": "unemployed",
        "traits": ["outdoorsman", "thick_skinned"],
        "clothing": {"clothing_top": "hoodie", "clothing_bottom": "jeans"},
        "accessories": ["beanie"],
        "body_type": "average",
        "cosmetics": {"cosmetic_face": "warpaint"},
    }


class CharacterValidationTests(unittest.TestCase):
    def test_valid_proposal_is_vanilla_only(self) -> None:
        catalog = test_catalog()
        clean = CharacterProposalValidator().validate(proposal(), catalog)
        self.assertEqual(clean.name, "Goblin")
        self.assertEqual(clean.clothing["clothing_top"], "hoodie")
        self.assertEqual(clean.cosmetics, {"cosmetic_face": "warpaint"})

    def test_non_vanilla_and_unknown_options_are_rejected(self) -> None:
        catalog = test_catalog()
        invalid = proposal()
        invalid["hair_style"] = "custom_mod_hair"
        with self.assertRaises(CharacterError):
            CharacterProposalValidator().validate(invalid, catalog)
        invalid = proposal()
        invalid["clothing"] = {"clothing_top": "workshop_asset"}
        with self.assertRaises(CharacterError):
            CharacterProposalValidator().validate(invalid, catalog)

    def test_catalog_rejects_non_vanilla_source(self) -> None:
        raw = test_catalog().as_dict()
        raw["options"]["hair_style"][0]["source"] = "mod"
        with self.assertRaises(CharacterError):
            VanillaCatalog.from_mapping(raw)


class CharacterLifecycleTests(unittest.TestCase):
    def test_existing_body_can_be_adopted_without_an_appearance_reset(self) -> None:
        persisted: list[tuple[CharacterLifecycle, dict[str, object] | None]] = []
        controller = CharacterCreationController(
            persist=lambda lifecycle, manifest: persisted.append((lifecycle, manifest))
        )

        self.assertTrue(controller.adopt_existing(now=100))
        self.assertEqual(controller.lifecycle, CharacterLifecycle.ACTIVE)
        self.assertEqual(
            controller.snapshot()["manifest"],
            {
                "generation": 0,
                "created_at": 100,
                "catalog_version": "adopted_existing",
                "creation_status": "adopted_existing",
                "adopted": True,
            },
        )
        self.assertFalse(controller.adopt_existing(now=200))
        self.assertEqual(len(persisted), 1)

    def test_creation_confirmation_death_respawn_and_recreation(self) -> None:
        catalog = test_catalog()
        persisted: list[tuple[CharacterLifecycle, dict[str, object] | None]] = []
        controller = CharacterCreationController(
            persist=lambda lifecycle, manifest: persisted.append((lifecycle, manifest))
        )

        created = controller.create(proposal(), catalog, now=100)
        self.assertTrue(created.accepted)
        self.assertEqual(created.status, "pending")
        self.assertEqual(controller.lifecycle, CharacterLifecycle.CREATION_PENDING)
        self.assertEqual(created.action.generation, 1)
        self.assertFalse(controller.confirm_creation(2))
        self.assertTrue(controller.confirm_creation(1))
        self.assertEqual(controller.lifecycle, CharacterLifecycle.ACTIVE)
        original_manifest = controller.snapshot()["manifest"]

        self.assertEqual(controller.on_death(), CharacterLifecycle.DEAD)
        self.assertEqual(controller.snapshot()["manifest"], original_manifest)
        self.assertEqual(controller.on_respawn(), CharacterLifecycle.ACTIVE)
        self.assertEqual(controller.snapshot()["manifest"], original_manifest)

        self.assertEqual(
            controller.mark_character_deleted(), CharacterLifecycle.RECREATE_REQUIRED
        )
        recreated = controller.create(proposal(), catalog, now=200)
        self.assertTrue(recreated.accepted)
        self.assertEqual(recreated.action.generation, 2)
        self.assertEqual(controller.lifecycle, CharacterLifecycle.CREATION_PENDING)
        self.assertTrue(controller.confirm_creation(2))
        self.assertEqual(controller.lifecycle, CharacterLifecycle.ACTIVE)
        self.assertGreaterEqual(len(persisted), 5)

    def test_native_default_recreation_advances_only_the_next_generation(self) -> None:
        persisted: list[tuple[CharacterLifecycle, dict[str, object] | None]] = []
        controller = CharacterCreationController(
            lifecycle=CharacterLifecycle.RECREATE_REQUIRED,
            manifest={"generation": 0, "adopted": True},
            persist=lambda lifecycle, manifest: persisted.append((lifecycle, manifest)),
        )

        self.assertFalse(controller.complete_native_recreation(2, now=200))
        self.assertTrue(controller.complete_native_recreation(1, now=200))
        self.assertEqual(controller.lifecycle, CharacterLifecycle.ACTIVE)
        self.assertEqual(
            controller.snapshot()["manifest"],
            {
                "generation": 1,
                "created_at": 200,
                "catalog_version": "native_default",
                "creation_status": "active",
                "creation_mode": "vanilla_default",
            },
        )
        self.assertEqual(len(persisted), 1)

    def test_equipment_can_only_use_found_vanilla_items(self) -> None:
        controller = CharacterCreationController()
        catalog = test_catalog()
        created = controller.create(proposal(), catalog, now=100)
        self.assertTrue(controller.confirm_creation(created.action.generation))
        found = [
            {"id": "old_hat", "category": "hat", "source": "vanilla", "found": True},
            {"id": "mod_hat", "category": "hat", "source": "mod", "found": True},
        ]
        self.assertEqual(
            controller.equipment_selection(found, ["old_hat"])["action"],
            "EQUIP_FOUND_VANILLA",
        )
        with self.assertRaises(CharacterError):
            controller.equipment_selection(found, ["mod_hat"])
        with self.assertRaises(CharacterError):
            controller.equipment_selection(found, ["not_found"])


class CharacterMemoryTests(unittest.TestCase):
    def test_character_state_survives_store_restart(self) -> None:
        temp_dir = Path(tempfile.mkdtemp(prefix="goblin-character-memory-"))
        path = temp_dir / "memory.sqlite3"
        try:
            first = MemoryStore(path)
            first.save_character_state(
                CharacterLifecycle.CREATION_PENDING.value,
                {"generation": 1, "appearance": proposal()},
                updated_at=123,
            )
            first.close()
            second = MemoryStore(path)
            try:
                record = second.character_record()
                self.assertEqual(record["lifecycle"], "creation_pending")
                self.assertEqual(record["manifest"]["generation"], 1)
                self.assertFalse(record["manifest_error"])
                self.assertEqual(record["updated_at"], 123)
            finally:
                second.close()
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
