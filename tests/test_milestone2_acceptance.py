import copy
from pathlib import Path
import unittest

from tools.check_milestone2_acceptance import validate
from tools.check_pz_catalog import CatalogError, read_catalog


ROOT = Path(__file__).resolve().parents[1]


class Milestone2AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.data = read_catalog(ROOT / "reference/pz-milestone2-live-acceptance.json")

    def test_repository_acceptance_is_source_bound_and_structured(self):
        self.assertEqual(validate(self.data, ROOT), (8, 2, 4))

    def test_free_text_cannot_replace_material_or_result_evidence(self):
        for mutation in ("materials", "result", "source"):
            with self.subTest(mutation=mutation):
                data = copy.deepcopy(self.data)
                if mutation == "materials":
                    data["native_craft_through_registry"]["material_observation"]["Base.Log_after"] = 1
                elif mutation == "result":
                    data["native_craft_through_registry"]["result_sequence"][1]["code"] = "WORKING"
                else:
                    data["source_sha256"]["GoblinJobs.lua"] = "0" * 64
                with self.assertRaises(CatalogError):
                    validate(data, ROOT)

    def test_client_and_release_boundaries_are_required(self):
        data = copy.deepcopy(self.data)
        data["clients"][0]["storm"] = True
        with self.assertRaises(CatalogError):
            validate(data, ROOT)
        data = copy.deepcopy(self.data)
        data["published"] = True
        with self.assertRaises(CatalogError):
            validate(data, ROOT)


if __name__ == "__main__":
    unittest.main()
