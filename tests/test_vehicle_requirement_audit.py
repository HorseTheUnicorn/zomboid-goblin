import unittest
from tests import test_pz_vehicle_details as fixture_module
from tests.test_pz_fixing_details import digest
from tools.audit_vehicle_requirements import audit


def table(**fields):
    return {'type': 'table', 'scalar': None, 'entries': [
        {'key_type': 'string', 'key': k, 'value': v if isinstance(v, dict) else
         {'type': 'string', 'scalar': v, 'entries': []}} for k, v in fields.items()]}


class VehicleRequirementAuditTests(unittest.TestCase):
    def setUp(self):
        fixture = fixture_module.VehicleDetailTests()
        fixture.setUp()
        self.detail, self.part = fixture.detail, fixture.part
        self.detail['schema_version'] = 2
        self.part['tables'] = {'install': table(items=table(first=table(type='Base.Jack', tags='base:wrench')),
                                              recipes='Basic Mechanics', requireInstalled='Battery')}
        self.items = {'records': [dict(full_type='Base.Jack', enabled=True, obsolete=False, tags=[]),
                                  dict(full_type='Base.Wrench', enabled=True, obsolete=False, tags=['base:wrench'])]}

    def run_audit(self):
        return audit({'vehicle_details': self.detail, 'vehicle_details_sha256': digest(self.detail)}, self.items)

    def test_exact_tags_knowledge_and_part_references_stay_separate(self):
        result = self.run_audit()
        self.assertTrue(result['exact_item_requirements']['Base.Jack']['resolved'])
        self.assertEqual(result['tag_requirements']['base:wrench']['alternatives'], {'base:wrench': ['Base.Wrench']})
        self.assertEqual(result['knowledge_names_not_craft_recipe_ids'], {'Basic Mechanics': 1})
        self.assertEqual(result['absent_part_references'], [])
        self.assertEqual(result['npc_compatibility'], 'UNVERIFIED')

    def test_obsolete_items_are_not_eligible_tag_matches(self):
        for record in self.items['records']: record['obsolete'] = True
        result = self.run_audit()
        self.assertFalse(result['exact_item_requirements']['Base.Jack']['resolved'])
        self.assertFalse(result['tag_requirements']['base:wrench']['has_installed_match'])

    def test_missing_targets_are_reported_without_inventing_defaults(self):
        self.part['tables']['install'] = table(requireUninstalled='NotInstalled')
        result = self.run_audit()
        self.assertEqual(result['absent_part_references'][0]['target'], 'NotInstalled')
        self.assertEqual(len(result['missing_test_fields']), 1)
        self.assertEqual(result['test_callbacks'], {})
