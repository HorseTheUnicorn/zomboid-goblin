import copy
import unittest
from tests.test_pz_fixing_details import digest
from tools.check_pz_catalog import CatalogError, validate_evolved_details


class EvolvedDetailTests(unittest.TestCase):
    def setUp(self):
        identities = {"schema_version": 1, "scope": "identity_only", "npc_compatibility": "UNKNOWN",
                      "records": [{"kind": "evolved_recipe", "id": "Base.Meal", "obsolete": False}]}
        details = {"schema_version": 1, "npc_compatibility": "UNKNOWN", "records": [{
            "id": "Base.Meal", "base": None, "result": None, "max_items": 6,
            "minimum_water": "0.5", "cookable": True, "ingredients": [{
                "item": {"declared": "Base.Food", "resolved": "Base.Food", "obsolete": False},
                "use": None, "cooked": None}]}]}
        self.proof = {"supplemental_catalog": identities, "supplemental_catalog_sha256": digest(identities),
                      "evolved_details": details, "evolved_details_sha256": digest(details)}
        self.items = {"records": [{"full_type": "Base.Food", "obsolete": False}]}

    def test_nullable_fields_and_no_mutation(self):
        before = copy.deepcopy(self.proof)
        self.assertEqual(validate_evolved_details(self.proof, self.items), {"Base.Meal"})
        self.assertEqual(self.proof, before)
        self.assertEqual(validate_evolved_details({}, self.items), set())
        with self.assertRaises(CatalogError): validate_evolved_details({}, self.items, required=True)

    def test_changed_water_invalidates_hash(self):
        self.proof["evolved_details"]["records"][0]["minimum_water"] = "1.0"
        with self.assertRaisesRegex(CatalogError, "hash mismatch"):
            validate_evolved_details(self.proof, self.items)

    def test_duplicate_ingredient_rejected(self):
        self.proof["evolved_details"]["records"][0]["ingredients"] *= 2
        with self.assertRaisesRegex(CatalogError, "Duplicate"):
            validate_evolved_details(self.proof, self.items)

    def test_missing_registry_coverage_rejected(self):
        self.proof["evolved_details"]["records"] = []
        with self.assertRaisesRegex(CatalogError, "omit"):
            validate_evolved_details(self.proof, self.items)
