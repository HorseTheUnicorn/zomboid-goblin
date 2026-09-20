import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from tools.check_goblin_inventory import validate_inventory, evidence_gaps, EVIDENCE_FIELDS
from tools.check_pz_catalog import CatalogError, read_catalog


ROOT = Path(__file__).resolve().parents[1]


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        # This is isolated test fixture creation, not an application source edit.
        (self.root / "source.lua").write_text("return {}", encoding="utf-8")
        self.inventory = {
            "schema_version": 1, "capabilities": [{
                "id": "EXISTING", "origin": "existing", "complete": False,
                "multiplayer_evidence": [], "required_items": ["Base.Tool"],
                "sources": [{"path": "source.lua", "sha256": hashlib.sha256(b"return {}").hexdigest()}],
            }], "remaining_existing_inventory": [],
            "remaining_proposed_inventory": ["FUTURE"], "engine_tested_capabilities": [],
        }
        self.commands = {"schema_version": 1, "inventory_status": "partial",
                         "existing_goblin_chat": {"commands": [
            {"command": "existing", "task": "EXISTING", "handler": "Module.handle"},
        ]}, "proposed_goblin_chat": [
            {"command": "future", "registered": False},
        ]}
        self.items = {"records": [{"full_type": "Base.Tool", "enabled": True, "obsolete": False}]}

    def check(self):
        return validate_inventory(self.inventory, self.commands, self.items, self.root)

    def test_partial_inventory_is_valid_but_not_complete(self):
        self.assertEqual(self.check(), (1, 0, 1))

    def test_evidence_gaps_do_not_infer_proof_from_sources_or_items(self):
        report = evidence_gaps(self.inventory)
        self.assertFalse(report["certifies_completion"])
        self.assertEqual(set(report["records"][0]["missing_fields"]), set(EVIDENCE_FIELDS))
        self.assertEqual(report["missing_counts"]["multiplayer_evidence"], 1)

    def test_filled_fields_are_not_completion_certification(self):
        record = self.inventory["capabilities"][0]
        for field in EVIDENCE_FIELDS:
            record[field] = "unreviewed claim"
        record["completion_evidence_required"] = ["unreviewed claim"]
        report = evidence_gaps(self.inventory)
        self.assertEqual(report["records"][0]["missing_fields"], [])
        self.assertFalse(report["certifies_completion"])

    def test_empty_or_scalar_fields_remain_gaps(self):
        for value in (None, " ", [], {}, True, 3):
            self.inventory["capabilities"][0]["target_class"] = value
            self.assertIn("target_class", evidence_gaps(self.inventory)["records"][0]["missing_fields"])

    def test_gap_audit_does_not_mutate_inventory(self):
        before = copy.deepcopy(self.inventory)
        evidence_gaps(self.inventory)
        self.assertEqual(self.inventory, before)

    def test_gap_audit_recognizes_established_nested_and_legacy_evidence_fields(self):
        record = self.inventory["capabilities"][0]
        record["native_api"] = {"public_documentation_url": "https://example.invalid/api"}
        record["rollback_reconciliation"] = "re-read authoritative state"
        record["verified_game"] = "test build"
        record["unit_tests"] = ["test_boundary"]
        missing = evidence_gaps(self.inventory)["records"][0]["missing_fields"]
        for field in ("public_documentation_url", "reconciliation_strategy",
                      "verified_versions", "unit_test_ids"):
            self.assertNotIn(field, missing)

    def test_reject_duplicate_and_overlapping_ids(self):
        self.inventory["capabilities"].append(copy.deepcopy(self.inventory["capabilities"][0]))
        with self.assertRaises(CatalogError): self.check()
        self.inventory["capabilities"].pop()
        self.inventory["remaining_existing_inventory"] = ["EXISTING"]
        with self.assertRaises(CatalogError): self.check()

    def test_registry_existence_does_not_certify_capability(self):
        self.inventory["capabilities"][0]["complete"] = True
        self.inventory["capabilities"][0]["multiplayer_evidence"] = ["it works"]
        with self.assertRaisesRegex(CatalogError, "physical evidence review"): self.check()

    def test_follow_requires_field_checked_structured_physical_evidence(self):
        record = self.inventory["capabilities"][0]
        record.update(id="FOLLOW", complete=True, physical_evidence_review={
            "kind": "MILESTONE_1_FOLLOW", "path": "acceptance.json",
        })
        self.commands["existing_goblin_chat"]["commands"][0]["task"] = "FOLLOW"
        acceptance = {
            "schema_version": 1,
            "clients": [
                {"ordinary_executable": True, "storm": False, "goblin_id": "one"},
                {"ordinary_executable": True, "storm": False, "goblin_id": "two"},
            ],
            "milestone_1": {"result": "pass", "requirements": [
                "stable follow slots", "native follow investigation",
                "expanded work approach search", "staged stuck recovery",
                "navigation telemetry", "temporary route blacklist",
            ], "live_scenarios_accepted": [
                "follow through open terrain", "follow through house doorway",
                "follow around furniture", "follow upstairs/downstairs",
                "owner runs through building", "work target surrounded on some sides",
                "path fails and recovers without teleport", "two players plus two Goblins",
            ]},
            "closed_door_follow": {"result": "pass"},
            "durable_radius_two_staging": {"result": "pass"},
            "open_terrain_running_follow": {"result": "pass", "teleport_after_measurement": False},
            "native_no_progress_recovery": {"result": "pass", "native_repath_attempts": 1, "teleport": False},
            "native_simulation_ownership_handoff": {"result": "pass", "staging": {"ownership_write": False, "goblin_teleport": False}},
            "furniture_detour": {"result": "pass", "occupied_obstacle_square": False, "follow_rejoin_during_measurement": False, "goblin_position_write": False},
            "stair_follow": {"result": "pass", "ascent_observations": [{"actor": {"z": 0.0}}, {"actor": {"z": 1.0}}], "descent_owner_client_trace": [{"actor": {"z": 0.2}}], "follow_rejoin_during_measurement": False, "goblin_position_write": False},
            "running_owner_building_follow": {"result": "pass", "owner_run": {"delta_tiles": 14}, "final_gap_tiles": 3.8, "actor_route": [{"native_state": "ClimbThroughWindowState"}, {"native_state": "PathFindState"}], "follow_rejoin_during_measurement": False, "goblin_position_write": False},
        }
        (self.root / "acceptance.json").write_text(
            json.dumps(acceptance), encoding="utf-8")
        self.assertEqual(self.check(), (1, 0, 1))
        acceptance["stair_follow"]["goblin_position_write"] = True
        (self.root / "acceptance.json").write_text(
            json.dumps(acceptance), encoding="utf-8")
        with self.assertRaisesRegex(CatalogError, "constraints failed"):
            self.check()

    def test_reject_engine_tested_claim_without_review(self):
        self.inventory["engine_tested_capabilities"] = ["EXISTING"]
        with self.assertRaises(CatalogError): self.check()

    def test_reject_missing_disabled_obsolete_items(self):
        for field, value in (("enabled", False), ("obsolete", True), ("full_type", "Base.Other")):
            with self.subTest(field=field):
                original = self.items["records"][0].copy()
                self.items["records"][0][field] = value
                with self.assertRaises(CatalogError): self.check()
                self.items["records"][0] = original

    def test_reject_stale_source_hash_and_outside_path(self):
        source = self.inventory["capabilities"][0]["sources"][0]
        source["sha256"] = "0" * 64
        with self.assertRaisesRegex(CatalogError, "source changed"): self.check()
        source["path"] = "../outside.lua"
        with self.assertRaisesRegex(CatalogError, "outside workspace"): self.check()

    def test_proposed_action_cannot_be_existing_chat_handler_task(self):
        self.commands["existing_goblin_chat"]["commands"][0]["task"] = "FUTURE"
        with self.assertRaises(CatalogError): self.check()

    def test_repository_inventory_consistency(self):
        ref = ROOT / "reference"
        count, existing, proposed = validate_inventory(
            read_catalog(ref / "goblin-capabilities.json"),
            read_catalog(ref / "goblin-commands.json"),
            read_catalog(ref / "pz-items.json"), ROOT)
        self.assertGreater(count, 0)
        self.assertGreaterEqual(existing, 0)
        self.assertGreaterEqual(proposed, 0)

    def test_cataloged_proposed_action_still_cannot_be_existing_command(self):
        future = copy.deepcopy(self.inventory["capabilities"][0])
        future.update(id="FUTURE", origin="proposed")
        self.inventory["capabilities"].append(future)
        self.inventory["remaining_proposed_inventory"] = []
        self.commands["existing_goblin_chat"]["commands"][0]["task"] = "FUTURE"
        with self.assertRaisesRegex(CatalogError, "unknown/proposed task"):
            self.check()

    def test_complete_command_inventory_requires_separate_boundaries(self):
        self.commands["inventory_status"] = (
            "complete_inventory_with_explicit_unimplemented_and_unverified_gaps"
        )
        with self.assertRaisesRegex(CatalogError, "natural-language routes"):
            self.check()

    def test_complete_capability_inventory_rejects_structural_gaps(self):
        self.inventory["inventory_status"] = (
            "complete_inventory_with_explicit_unimplemented_and_unverified_gaps"
        )
        self.inventory["remaining_proposed_inventory"] = []
        with self.assertRaisesRegex(CatalogError, "structural gaps"):
            self.check()

    def test_proposed_command_must_remain_unregistered(self):
        self.commands["proposed_goblin_chat"][0]["registered"] = True
        with self.assertRaisesRegex(CatalogError, "explicitly unregistered"):
            self.check()
