import unittest
from tests.test_pz_fixing_details import digest
from tests.test_vehicle_requirement_audit import table
from tools.audit_trap_requirements import audit


class TrapRequirementAuditTests(unittest.TestCase):
    def setUp(self):
        trap = table(type='Base.Trap', destroyItem=table(first='Base.Wood'))
        # Numeric sequence keys must match the runtime typed representation.
        trap['entries'][1]['value']['entries'][0]['key_type'] = 'number'
        trap['entries'][1]['value']['entries'][0]['key'] = '1.0'
        animal = table(type='rabbit', item='Base.Rabbit',
                       baits=table(**{'Base.Bait': '10'}), traps=table(**{'Base.Trap': '20'}))
        self.detail = {'schema_version': 1, 'npc_compatibility': 'UNKNOWN',
                       'traps': {'type': 'table', 'scalar': None, 'entries': [
                           {'key_type': 'number', 'key': '1.0', 'value': trap}]},
                       'animals': {'type': 'table', 'scalar': None, 'entries': [
                           {'key_type': 'number', 'key': '1.0', 'value': animal}]},
                       'forage': []}
        self.items = {'records': [dict(full_type=value, enabled=True, obsolete=False)
                                  for value in ('Base.Trap', 'Base.Wood', 'Base.Rabbit', 'Base.Bait')]}

    def run_audit(self):
        return audit({'survival_details': self.detail,
                      'survival_details_sha256': digest(self.detail)}, self.items)

    def test_item_roles_resolve_separately(self):
        result = self.run_audit()
        self.assertEqual(result['bait_item_ids'], ['Base.Bait'])
        self.assertEqual(result['catch_item_ids'], ['Base.Rabbit'])
        self.assertEqual(result['traps'][0]['destroy_items'], ['Base.Wood'])
        self.assertEqual(result['unavailable_item_ids'], [])
        self.assertEqual(result['npc_compatibility'], 'UNVERIFIED')

    def test_obsolete_or_disabled_reference_is_unavailable(self):
        self.items['records'][-1]['obsolete'] = True
        self.assertEqual(self.run_audit()['unavailable_item_ids'], ['Base.Bait'])

    def test_unknown_trap_is_reported_without_guessing(self):
        animal = self.detail['animals']['entries'][0]['value']
        next(e for e in animal['entries'] if e['key'] == 'traps')['value']['entries'][0]['key'] = 'Base.OtherTrap'
        result = self.run_audit()
        self.assertEqual(result['animals'][0]['unknown_traps'], ['Base.OtherTrap'])
        self.assertIn('Base.OtherTrap', result['unavailable_item_ids'])


if __name__ == '__main__':
    unittest.main()
