import unittest
from tests.test_pz_fixing_details import digest
from tools.check_pz_catalog import CatalogError, validate_crop_details


class CropDetailTests(unittest.TestCase):
    def setUp(self):
        self.crop = {"name": "Barley", "seed_name": "Base.Sheaf", "vegetable_name": "Base.Sheaf",
                     "produce_extra": None, "season_recipe": "base:knowledge", "seed_types": ["Base.Seed"]}
        self.detail = {"schema_version": 1, "npc_compatibility": "UNKNOWN", "records": [self.crop]}
        self.items = {"records": [{"full_type": "Base.Sheaf"}, {"full_type": "Base.Seed"}]}

    def validate(self):
        return validate_crop_details({"crop_details": self.detail, "crop_details_sha256": digest(self.detail)}, self.items)

    def test_knowledge_not_an_item_or_craft_recipe(self):
        self.assertEqual(self.validate(), {"crops": {"Barley"}, "unresolved_items": set()})

    def test_missing_seed_not_replaced_with_produce(self):
        self.crop["seed_types"] = ["Missing.Seed"]
        self.assertEqual(self.validate()["unresolved_items"], {"Missing.Seed"})

    def test_null_empty_and_missing_export(self):
        for seeds in (None, []):
            self.crop["seed_types"] = seeds
            self.assertEqual(self.validate()["unresolved_items"], set())
            self.assertEqual(self.crop["seed_types"], seeds)
        with self.assertRaises(CatalogError): validate_crop_details({}, self.items, required=True)

    def test_duplicate_and_tampered(self):
        proof = {"crop_details": self.detail, "crop_details_sha256": digest(self.detail)}
        self.crop["seed_types"] = []
        with self.assertRaisesRegex(CatalogError, "hash mismatch"): validate_crop_details(proof, self.items)
        self.detail["records"].append(self.crop.copy())
        with self.assertRaisesRegex(CatalogError, "duplicate"): self.validate()
