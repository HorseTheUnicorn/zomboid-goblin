import copy
import hashlib
import json
import unittest

from tools.check_pz_catalog import CatalogError, validate_supplemental_catalog


class SupplementalTests(unittest.TestCase):
    def fixture(self):
        catalog = {"schema_version": 1, "scope": "identity_only", "npc_compatibility": "UNKNOWN",
                   "records": [{"kind": "fixing", "id": 'Base.A"ü', "obsolete": False}]}
        digest = hashlib.sha256(json.dumps(catalog, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        return {"supplemental_catalog": catalog, "supplemental_catalog_sha256": digest}

    def test_valid_and_legacy_optional(self):
        self.assertEqual(validate_supplemental_catalog(self.fixture()), {("fixing", 'Base.A"ü')})
        self.assertEqual(validate_supplemental_catalog({}), set())
        with self.assertRaises(CatalogError): validate_supplemental_catalog({}, required=True)

    def test_tampered_missing_or_half_extension(self):
        for key in ("supplemental_catalog", "supplemental_catalog_sha256"):
            proof = self.fixture()
            del proof[key]
            with self.assertRaises(CatalogError): validate_supplemental_catalog(proof)
        proof = self.fixture()
        proof["supplemental_catalog"]["records"][0]["id"] = "Base.Other"
        with self.assertRaisesRegex(CatalogError, "hash mismatch"): validate_supplemental_catalog(proof)

    def test_invalid_claims_and_fields(self):
        for field, value in (("npc_compatibility", "SUPPORTED"), ("schema_version", True), ("scope", "complete")):
            proof = self.fixture()
            proof["supplemental_catalog"][field] = value
            with self.assertRaises(CatalogError): validate_supplemental_catalog(proof)
        for field, value in (("kind", "craft"), ("id", " "), ("obsolete", 0)):
            proof = self.fixture()
            proof["supplemental_catalog"]["records"][0][field] = value
            with self.assertRaises(CatalogError): validate_supplemental_catalog(proof)

    def test_duplicates_and_nonmutation(self):
        proof = self.fixture()
        before = copy.deepcopy(proof)
        validate_supplemental_catalog(proof)
        self.assertEqual(proof, before)
        proof["supplemental_catalog"]["records"] *= 2
        with self.assertRaisesRegex(CatalogError, "Duplicate"): validate_supplemental_catalog(proof)
