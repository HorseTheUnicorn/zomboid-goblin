import unittest
from tests.test_pz_fixing_details import digest
from tests.test_vehicle_requirement_audit import table
from tools.check_pz_catalog import CatalogError, validate_survival_details


class SurvivalDetailTests(unittest.TestCase):
    def setUp(self):
        self.forage = {'id': 'Base.Stone', 'fields': {'type': {
            'type': 'string', 'scalar': 'Base.Stone', 'entries': []}}, 'unexported_fields': ['spawnFuncs']}
        self.detail = {'schema_version': 1, 'npc_compatibility': 'UNKNOWN',
                       'traps': table(first=table(type='Base.Trap', destroyItem='Base.Wood')),
                       'animals': table(first=table(item='Base.Animal', baits=table(**{'Base.Bait': '10'}))),
                       'forage': [self.forage]}
        self.items = {'records': [{'full_type': v} for v in
                                 ('Base.Stone', 'Base.Trap', 'Base.Wood', 'Base.Animal', 'Base.Bait')]}

    def validate(self):
        return validate_survival_details({'survival_details': self.detail,
                                          'survival_details_sha256': digest(self.detail)}, self.items)

    def test_references_resolve_but_callbacks_remain_unexported(self):
        self.assertEqual(self.validate(), {'forage': {'Base.Stone'}, 'traps': 1, 'animals': 1, 'unresolved_items': set()})
        self.assertEqual(self.forage['unexported_fields'], ['spawnFuncs'])

    def test_missing_items_are_not_guessed(self):
        self.items['records'].pop()
        self.assertEqual(self.validate()['unresolved_items'], {'Base.Bait'})

    def test_mismatch_duplicate_and_omission_overlap_rejected(self):
        self.forage['id'] = 'Other.Stone'
        with self.assertRaisesRegex(CatalogError, 'mismatch'): self.validate()
        self.forage['id'] = 'Base.Stone'
        self.detail['forage'].append(self.forage.copy())
        with self.assertRaisesRegex(CatalogError, 'duplicate'): self.validate()
        self.detail['forage'].pop()
        self.forage['unexported_fields'].append('type')
        with self.assertRaisesRegex(CatalogError, 'omissions'): self.validate()

    def test_missing_and_tampered_exports_rejected(self):
        with self.assertRaises(CatalogError): validate_survival_details({}, self.items, required=True)
        proof = {'survival_details': self.detail, 'survival_details_sha256': digest(self.detail)}
        self.forage['unexported_fields'] = []
        with self.assertRaisesRegex(CatalogError, 'hash mismatch'):
            validate_survival_details(proof, self.items)
