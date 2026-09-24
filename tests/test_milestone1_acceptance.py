import copy
import hashlib
from pathlib import Path
import unittest

from tools.check_milestone1_acceptance import (
    CURRENT_SOURCES, SERVER_JAR, validate, validate_historical_record,
)
from tools.check_pz_catalog import CatalogError, read_catalog


ROOT = Path(__file__).resolve().parents[1]


class Milestone1AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.data = read_catalog(ROOT / "reference/pz-milestone1-live-acceptance.json")

    @staticmethod
    def _native_run_trace():
        # Synthetic verifier fixture, not evidence of a live game run.
        return [
            {"timestamp_ms": 1000 + index * 1000, "client": "horse",
             "entity_id": "dev.survivor.001.horse", "online_id": 42, "remote": False,
             "player": {"x": index * 4, "y": 0, "z": 0},
             "actor": {"x": index * 3, "y": 0, "z": 0},
             "player_running": True, "player_sprinting": False}
            for index in range(4)
        ]

    def _current_record(self):
        data = copy.deepcopy(self.data)
        data["schema_version"] = 2
        data["source_sha256"] = {
            name: hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
            for name, relative in CURRENT_SOURCES.items()
        }
        data["server_jar_sha256"] = hashlib.sha256((ROOT / SERVER_JAR).read_bytes()).hexdigest()
        for gate in ("open_terrain_running_follow", "running_owner_building_follow"):
            data[gate]["owner_username"] = "horse"
            data[gate]["owning_client_trace"] = self._native_run_trace()
        return data

    def test_historical_pass_does_not_certify_changed_sources(self):
        self.assertEqual(validate_historical_record(self.data), (6, 2, 9))
        with self.assertRaisesRegex(CatalogError, "legacy evidence cannot certify current source"):
            validate(self.data, ROOT)

    def test_current_record_binds_follow_and_authority_modules(self):
        # Synthetic in-memory verifier fixture, not a live acceptance record.
        data = self._current_record()
        with self.assertRaisesRegex(CatalogError, "continuous no-teleport actor trace"):
            validate(data, ROOT)
        handoff = data["native_simulation_ownership_handoff"]
        handoff["follow_rejoin_during_measurement"] = False
        handoff["goblin_position_write"] = False
        handoff["actor_trace"] = [
            {"timestamp_ms": 1000 + index * 1000,
             "actor": {"x": index, "y": 0, "z": 0},
             "native_owner_player": "unicorn" if index in (1, 2) else "horse"}
            for index in range(5)
        ]
        self.assertEqual(validate(data, ROOT), (17, 2, 9))
        handoff["actor_trace"][2]["actor"]["x"] = 20
        with self.assertRaisesRegex(CatalogError, "teleport-sized actor step"):
            validate(data, ROOT)
        handoff["actor_trace"][2]["actor"]["x"] = 2
        handoff["actor_trace"][2]["timestamp_ms"] = 6000
        with self.assertRaisesRegex(CatalogError, "unobserved or teleport-sized actor step"):
            validate(data, ROOT)
        handoff["actor_trace"][2]["timestamp_ms"] = 3000
        del data["source_sha256"]["GoblinAutonomy.lua"]
        with self.assertRaisesRegex(CatalogError, "source manifest is incomplete"):
            validate(data, ROOT)
        data["source_sha256"]["GoblinAutonomy.lua"] = "0" * 64
        with self.assertRaisesRegex(CatalogError, "source changed since acceptance: GoblinAutonomy.lua"):
            validate(data, ROOT)
        data["source_sha256"]["GoblinAutonomy.lua"] = hashlib.sha256(
            (ROOT / CURRENT_SOURCES["GoblinAutonomy.lua"]).read_bytes()).hexdigest()
        data["server_jar_sha256"] = "0" * 64
        with self.assertRaisesRegex(CatalogError, "server JAR changed since acceptance"):
            validate(data, ROOT)
        del data["server_jar_sha256"]
        with self.assertRaisesRegex(CatalogError, "server JAR hash is missing"):
            validate(data, ROOT)

    def test_current_running_gate_rejects_walk_to_and_missing_trace(self):
        data = self._current_record()
        gate = data["open_terrain_running_follow"]
        del gate["owning_client_trace"]
        with self.assertRaisesRegex(CatalogError, "continuous native running trace"):
            validate(data, ROOT)
        gate["owning_client_trace"] = self._native_run_trace()
        for sample in gate["owning_client_trace"]:
            sample["player_running"] = False
        with self.assertRaisesRegex(CatalogError, "no sustained running-owner follow movement"):
            validate(data, ROOT)
        gate["owning_client_trace"] = self._native_run_trace()
        gate["owning_client_trace"][2]["timestamp_ms"] = 4000
        with self.assertRaisesRegex(CatalogError, "gap or teleport-sized step"):
            validate(data, ROOT)
        gate["owning_client_trace"] = self._native_run_trace()
        gate["owning_client_trace"][2]["remote"] = True
        with self.assertRaisesRegex(CatalogError, "owning-client actor observations"):
            validate(data, ROOT)
        gate["owning_client_trace"] = self._native_run_trace()
        gate["owning_client_trace"][-1]["actor"]["x"] = 3
        with self.assertRaisesRegex(CatalogError, "no sustained running-owner follow movement"):
            validate(data, ROOT)

    def test_current_building_gate_requires_native_running(self):
        data = self._current_record()
        handoff = data["native_simulation_ownership_handoff"]
        handoff["follow_rejoin_during_measurement"] = False
        handoff["goblin_position_write"] = False
        handoff["actor_trace"] = [
            {"timestamp_ms": 1000 + index * 1000,
             "actor": {"x": index, "y": 0, "z": 0},
             "native_owner_player": "unicorn" if index in (1, 2) else "horse"}
            for index in range(5)
        ]
        data["running_owner_building_follow"]["owning_client_trace"][1]["player_sprinting"] = None
        with self.assertRaisesRegex(CatalogError, "native run state is missing"):
            validate(data, ROOT)

    def test_missing_physical_or_authority_proof_is_rejected(self):
        for mutation in ("crossing", "materials", "handoff", "teleport"):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(self.data)
                if mutation == "crossing":
                    data["closed_door_follow"]["crossed"] = False
                elif mutation == "materials":
                    data["durable_radius_two_staging"]["stage_reached"] = False
                elif mutation == "handoff":
                    data["native_simulation_ownership_handoff"]["staging"]["ownership_write"] = True
                else:
                    data["open_terrain_running_follow"]["teleport_after_measurement"] = True
                with self.assertRaises(CatalogError):
                    validate_historical_record(data)

    def test_client_topology_and_source_manifest_are_required(self):
        data = copy.deepcopy(self.data)
        data["clients"][0]["storm"] = True
        with self.assertRaises(CatalogError):
            validate_historical_record(data)
        data = copy.deepcopy(self.data)
        del data["source_sha256"]["GoblinLocomotion.lua"]
        with self.assertRaises(CatalogError):
            validate_historical_record(data)


if __name__ == "__main__":
    unittest.main()
