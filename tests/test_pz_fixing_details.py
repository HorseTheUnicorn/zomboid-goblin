import copy
import hashlib
import json
import unittest
from tools.check_pz_catalog import CatalogError, validate_fixing_details


def digest(value):
    return hashlib.sha256(json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


class FixingDetailTests(unittest.TestCase):
    def setUp(self):
        supplement = {"schema_version": 1, "scope": "identity_only", "npc_compatibility": "UNKNOWN",
                      "records": [{"kind": "fixing", "id": "Base.Repair", "obsolete": False}]}
        item = {"declared": "Base.Tool", "resolved": "Base.Tool", "obsolete": False}
        detail = {"schema_version": 1, "npc_compatibility": "UNKNOWN", "records": [{
            "id": "Base.Repair", "targets": [item], "alternatives": [
                {"item": item.copy(), "uses": 2, "skills": [{"name": "Mechanics", "level": 3}]}],
            "global": None, "condition_modifier": "1.0"}]}
        self.proof = {"supplemental_catalog": supplement, "supplemental_catalog_sha256": digest(supplement),
                      "fixing_details": detail, "fixing_details_sha256": digest(detail)}
        self.items = {"records": [{"full_type": "Base.Tool", "obsolete": False}]}

    def test_valid_legacy_and_nonmutation(self):
        before = copy.deepcopy(self.proof)
        self.assertEqual(validate_fixing_details(self.proof, self.items), {"Base.Repair"})
        self.assertEqual(self.proof, before)
        self.assertEqual(validate_fixing_details({}, self.items), set())
        with self.assertRaises(CatalogError): validate_fixing_details({}, self.items, required=True)

    def test_changed_cost_invalidates_hash(self):
        self.proof["fixing_details"]["records"][0]["alternatives"][0]["uses"] = 9
        with self.assertRaisesRegex(CatalogError, "hash mismatch"):
            validate_fixing_details(self.proof, self.items)

    def test_unknown_item_and_omitted_definition(self):
        self.items["records"] = []
        with self.assertRaisesRegex(CatalogError, "Unknown resolved"):
            validate_fixing_details(self.proof, self.items)
        self.proof["fixing_details"]["records"] = []
        with self.assertRaisesRegex(CatalogError, "omit"):
            validate_fixing_details(self.proof, self.items)

    def test_unresolved_is_explicit_not_guessed(self):
        ref = self.proof["fixing_details"]["records"][0]["alternatives"][0]["item"]
        ref.update(declared="Missing", resolved=None)
        self.proof["fixing_details_sha256"] = digest(self.proof["fixing_details"])
        self.assertEqual(validate_fixing_details(self.proof, self.items), {"Base.Repair"})
