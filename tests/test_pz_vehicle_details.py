import unittest
from tests.test_pz_fixing_details import digest
from tools.check_pz_catalog import CatalogError, validate_vehicle_details, validate_definition_node


class VehicleDetailTests(unittest.TestCase):
    def setUp(self):
        self.part = dict(id="Battery", parent=None, area="Engine", mechanic_area=None,
                         item_types=["Base.CarBattery1"], specific_item=True,
                         requires_key=False, repair_mechanic=True,
                         callbacks={"test": "Vehicles.Test.Battery"}, table_names=["install"])
        self.vehicle = dict(id="Base.Car", mechanic_type=1, engine_repair_level=4, parts=[self.part])
        self.detail = dict(schema_version=1, npc_compatibility="UNKNOWN", records=[self.vehicle])
        self.items = {"records": [{"full_type": "Base.CarBattery1"}]}

    def validate(self):
        return validate_vehicle_details({"vehicle_details": self.detail,
                                         "vehicle_details_sha256": digest(self.detail)}, self.items)

    def test_items_resolve_but_callback_names_are_not_item_identifiers(self):
        self.assertEqual(self.validate(), {"vehicles": {"Base.Car"}, "parts": 1, "unresolved_items": set()})

    def test_no_namespace_guessing_and_null_differs_from_empty(self):
        self.part["item_types"] = ["CarBattery1"]
        self.assertEqual(self.validate()["unresolved_items"], {"CarBattery1"})
        for value in (None, []):
            self.part["item_types"] = value
            self.assertEqual(self.validate()["unresolved_items"], set())
            self.assertEqual(self.part["item_types"], value)

    def test_duplicates_bad_flags_and_claims_rejected(self):
        self.vehicle["parts"].append(self.part.copy())
        with self.assertRaisesRegex(CatalogError, "duplicate"): self.validate()
        self.vehicle["parts"].pop()
        self.part["requires_key"] = 1
        with self.assertRaises(CatalogError): self.validate()
        self.part["requires_key"] = False
        self.detail["npc_compatibility"] = "SUPPORTED"
        with self.assertRaises(CatalogError): self.validate()

    def test_missing_export_and_tampering_rejected(self):
        with self.assertRaises(CatalogError): validate_vehicle_details({}, self.items, required=True)
        proof = {"vehicle_details": self.detail, "vehicle_details_sha256": digest(self.detail)}
        self.part["requires_key"] = True
        with self.assertRaisesRegex(CatalogError, "hash mismatch"):
            validate_vehicle_details(proof, self.items)

    def test_v2_nested_requirements_and_table_coverage(self):
        self.detail['schema_version'] = 2
        self.part['tables'] = {'install': {'type': 'table', 'scalar': None, 'entries': [
            {'key_type': 'string', 'key': 'test', 'value': {
                'type': 'string', 'scalar': 'Vehicles.InstallTest.Default', 'entries': []}}]}}
        self.assertEqual(self.validate()['parts'], 1)
        self.part['tables'] = {}
        with self.assertRaisesRegex(CatalogError, 'contents differ'): self.validate()

    def test_requiring_tables_rejects_old_or_absent_capture(self):
        for proof in ({}, {'vehicle_details': self.detail, 'vehicle_details_sha256': digest(self.detail)}):
            with self.assertRaises(CatalogError):
                validate_vehicle_details(proof, self.items, require_tables=True)

    def test_typed_keys_and_duplicate_numeric_keys(self):
        leaf = {'type': 'boolean', 'scalar': 'true', 'entries': []}
        root = {'type': 'table', 'scalar': None, 'entries': [
            {'key_type': 'number', 'key': '1.0', 'value': leaf},
            {'key_type': 'string', 'key': '1', 'value': leaf}]}
        self.assertEqual(validate_definition_node(root), root)
        root['entries'][1]['key_type'] = 'number'
        with self.assertRaisesRegex(CatalogError, 'Duplicate'): validate_definition_node(root)

    def test_bad_scalar_and_deep_nesting_rejected(self):
        for kind, value in (('number', 'NaN'), ('boolean', 'yes'), ('function', 'call')):
            with self.assertRaises(CatalogError):
                validate_definition_node({'type': kind, 'scalar': value, 'entries': []})
        node = {'type': 'string', 'scalar': 'x', 'entries': []}
        for _ in range(14):
            node = {'type': 'table', 'scalar': None, 'entries': [
                {'key_type': 'string', 'key': 'child', 'value': node}]}
        with self.assertRaisesRegex(CatalogError, 'bound'): validate_definition_node(node)
