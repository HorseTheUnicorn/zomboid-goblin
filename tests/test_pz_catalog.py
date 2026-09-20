import copy
import hashlib
import json
import unittest

from tools.check_pz_catalog import CatalogError, reject_duplicate_keys, resolve_identifier, validate_records, validate_export_set, canonical_hash, validate_content_manifest


def item_catalog():
    provenance = {"game_build": "test-build", "enabled_mods_fingerprint": None,
                  "export_timestamp": "2026-09-19T00:00:00Z"}
    return {"schema_version": 1, "kind": "pz-items", **provenance, "records": [
        {"full_type": "Fixture.Hammer", "tags": ["Tool"], "weight": 1.0,
         "display_name": "Hammer", "display_category": "Tool", "source_mod": "fixture", "source_file": "fixture.txt",
         "reusable_tool_roles": None, "consumable_state": None, "evidence": {"definition": "RUNTIME_RESOLVED"},
         "lookup_by_id": True, "enabled": True, "obsolete": False, **provenance},
    ]}


def recipe_catalog():
    provenance = {field: item_catalog()[field] for field in ("game_build", "enabled_mods_fingerprint", "export_timestamp")}
    return {"schema_version": 1, "kind": "pz-recipes", **provenance, "records": [{
        "recipe_id": "Fixture.Recipe", "name": "Recipe", "mod_id": "fixture", "tags": [],
        "enabled": True, "obsolete": False, "requires_player": False,
        "lookup_key": "Fixture.Recipe", "lookup_by_id": True, "lookup_by_name": True,
        "lookup_evidence": "identity roundtrip", "lua_callbacks": None, "npc_compatibility": "UNKNOWN",
        "inputs": [{"items": [], "possible_items": [], "item_tags": [], "amount": 1.0, "max_amount": 1.0,
                    "variable_amount": False, "tool": False, "keep": False, "destroy": False,
                    "resource_type": "Fluid", "possible_fluids": None, "possible_energies": None,
                    "resource_evidence": {"fluids": "UNKNOWN"}}], "outputs": [], **provenance,
    }]}


def export_set():
    items, recipes = item_catalog(), recipe_catalog()
    raw = {"pz-items.json": json.dumps(items).encode(), "pz-recipes.json": json.dumps(recipes).encode()}
    proof = {"schema_version": 1, "kind": "pz-runtime-fingerprint",
             **{field: items[field] for field in ("game_build", "enabled_mods_fingerprint", "export_timestamp")},
             "enabled_mods_fingerprint_status": "UNKNOWN",
             "export_files_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in raw.items()}}
    return items, recipes, proof, raw


class CatalogTests(unittest.TestCase):
    def content_proof(self):
        roots = [{"bytes": 0, "file_count": 0, "path": "common", "sha256": None, "status": "ABSENT"},
                 {"bytes": 3, "file_count": 1, "path": "42", "sha256": "a" * 64, "status": "PRESENT"}]
        content = [{"mod_id": "fixture-ünicode", "roots": roots, "sha256": canonical_hash(roots)}]
        return {"enabled_mods": ["fixture-ünicode"], "enabled_mods_content": content,
                "enabled_mods_content_algorithm": "selected-common-version-roots-v1",
                "enabled_mods_fingerprint": canonical_hash(content)}

    def test_selected_content_manifest_integrity(self):
        proof = self.content_proof()
        validate_content_manifest(proof)
        proof["enabled_mods_content"][0]["roots"][1]["bytes"] = 4
        with self.assertRaises(CatalogError):
            validate_content_manifest(proof)

    def test_common_only_mod_is_valid(self):
        proof = self.content_proof()
        entry = proof["enabled_mods_content"][0]
        entry["roots"][0].update(bytes=3, file_count=1, sha256="a" * 64, status="PRESENT")
        entry["roots"][1].update(bytes=0, file_count=0, sha256=None, status="ABSENT")
        entry["sha256"] = canonical_hash(entry["roots"])
        proof["enabled_mods_fingerprint"] = canonical_hash(proof["enabled_mods_content"])
        validate_content_manifest(proof)

    def test_selected_content_rejects_unbound_roots_and_bad_selection(self):
        for field, value in (("path", "../other"), ("file_count", 0), ("status", "ABSENT")):
            proof = self.content_proof()
            proof["enabled_mods_content"][0]["roots"][1][field] = value
            with self.assertRaises(CatalogError):
                validate_content_manifest(proof)
        proof = self.content_proof()
        proof["enabled_mods"] = ["different"]
        with self.assertRaises(CatalogError):
            validate_content_manifest(proof)

    def test_selected_content_bound_to_catalog_export(self):
        items, recipes, proof, raw = export_set()
        proof.update(self.content_proof())
        proof["enabled_mods_fingerprint_status"] = "CONTENT_VERIFIED"
        for document in (items, recipes):
            document["enabled_mods_fingerprint"] = proof["enabled_mods_fingerprint"]
            for record in document["records"]:
                record["enabled_mods_fingerprint"] = proof["enabled_mods_fingerprint"]
        raw = {"pz-items.json": json.dumps(items).encode(), "pz-recipes.json": json.dumps(recipes).encode()}
        proof["export_files_sha256"] = {key: hashlib.sha256(value).hexdigest() for key, value in raw.items()}
        validate_export_set(items, recipes, proof, raw, require_runtime=True)

    def test_unknown_provenance_is_structural_only(self):
        self.assertEqual(validate_records(item_catalog(), "full_type"), {"Fixture.Hammer"})
        with self.assertRaises(CatalogError):
            validate_records(item_catalog(), "full_type", require_runtime=True)

    def test_exact_id_wins_over_alias(self):
        self.assertEqual(resolve_identifier("Fixture.Hammer", {"Fixture.Hammer"}, {}), "Fixture.Hammer")

    def test_explicit_alias_must_resolve_uniquely(self):
        ids = {"Fixture.Hammer", "Other.Hammer"}
        self.assertEqual(resolve_identifier("hammer", ids, {"hammer": ["Fixture.Hammer"]}), "Fixture.Hammer")
        for aliases in ({}, {"hammer": ["Fixture.Hammer", "Other.Hammer"]}, {"hammer": ["Missing.Hammer"]}):
            with self.assertRaises(CatalogError):
                resolve_identifier("hammer", ids, aliases)

    def test_duplicate_identifiers_fail(self):
        catalog = item_catalog()
        catalog["records"].append(copy.deepcopy(catalog["records"][0]))
        with self.assertRaises(CatalogError):
            validate_records(catalog, "full_type")

    def test_mismatched_record_provenance_fails(self):
        catalog = item_catalog()
        catalog["records"][0]["game_build"] = "different-build"
        with self.assertRaises(CatalogError):
            validate_records(catalog, "full_type")

    def test_registry_cannot_claim_engine_acceptance(self):
        catalog = item_catalog()
        catalog["records"][0]["engine_tested"] = True
        with self.assertRaises(CatalogError):
            validate_records(catalog, "full_type")

    def test_invalid_weight_and_tags_fail(self):
        for field, value in (("weight", float("nan")), ("weight", True), ("tags", ["z", "a"]), ("tags", [1])):
            catalog = item_catalog()
            catalog["records"][0][field] = value
            with self.assertRaises(CatalogError):
                validate_records(catalog, "full_type")

    def test_duplicate_json_keys_fail(self):
        with self.assertRaises(CatalogError):
            reject_duplicate_keys([("records", []), ("records", [])])

    def test_required_item_metadata_cannot_be_omitted(self):
        for field in ("display_name", "source_mod", "evidence", "reusable_tool_roles", "enabled", "lookup_by_id"):
            catalog = item_catalog()
            del catalog["records"][0][field]
            with self.assertRaises(CatalogError):
                validate_records(catalog, "full_type")

    def test_recipe_resource_semantics_and_unknown_compatibility(self):
        self.assertEqual(validate_records(recipe_catalog(), "recipe_id"), {"Fixture.Recipe"})
        for field in ("resource_type", "resource_evidence", "possible_fluids"):
            catalog = recipe_catalog()
            del catalog["records"][0]["inputs"][0][field]
            with self.assertRaises(CatalogError):
                validate_records(catalog, "recipe_id")
        catalog = recipe_catalog()
        catalog["records"][0]["npc_compatibility"] = "SUPPORTED"
        with self.assertRaises(CatalogError):
            validate_records(catalog, "recipe_id")

    def test_export_commit_hashes_bind_both_files(self):
        items, recipes, proof, raw = export_set()
        validate_export_set(items, recipes, proof, raw)
        raw["pz-items.json"] += b" "
        with self.assertRaises(CatalogError):
            validate_export_set(items, recipes, proof, raw)

    def test_order_hash_is_not_content_proof(self):
        items, recipes, proof, raw = export_set()
        with self.assertRaises(CatalogError):
            validate_export_set(items, recipes, proof, raw, require_runtime=True)

    def test_hash_shaped_string_without_export_set_cannot_pass_runtime(self):
        catalog = item_catalog()
        catalog["enabled_mods_fingerprint"] = "0" * 64
        catalog["records"][0]["enabled_mods_fingerprint"] = "0" * 64
        with self.assertRaises(CatalogError):
            validate_records(catalog, "full_type", require_runtime=True)

    def test_missing_timestamp_and_wrong_kind_fail(self):
        for field, value in (("export_timestamp", None), ("kind", "pz-recipes"), ("schema_version", True)):
            catalog = item_catalog()
            catalog[field] = value
            with self.assertRaises(CatalogError):
                validate_records(catalog, "full_type")


if __name__ == "__main__":
    unittest.main()
