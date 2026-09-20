import unittest
from tests.test_pz_fixing_details import digest
from tests.test_vehicle_requirement_audit import table
from tools.check_pz_catalog import CatalogError, validate_fishing_details


def seq(*values):
    entries = []
    for index, value in enumerate(values, 1):
        if not isinstance(value, dict):
            value = {'type': 'string', 'scalar': value, 'entries': []}
        entries.append({'key_type': 'number', 'key': f'{index}.0', 'value': value})
    return {'type': 'table', 'scalar': None, 'entries': entries}


class FishingDetailTests(unittest.TestCase):
    def setUp(self):
        lure_data = table(chanceModifier='1')
        categories = table(Insect=table(**{'Base.Worm': lure_data}),
                           All=table(**{'Base.Worm': lure_data}))
        fish = table(itemType='Base.Fish', lure=table(**{'Base.Worm': '1'}))
        self.fields = {
            'lure': categories, 'fishes': seq(fish), 'trashItems': seq('Base.Trash'),
            'line': table(**{'Base.Line': '0.1'}), 'hook': table(**{'Base.Hook': '1'}),
            'rods': table(**{'Base.Rod': '1'}),
            'breakRodReplacement': table(**{'Base.Rod': 'Base.BrokenRod'}),
            'fishNet': seq('Base.Fish'), 'fishNetWithBait': seq('Base.Fish')}
        self.fields = dict(sorted(self.fields.items()))
        self.detail = {'schema_version': 1, 'npc_compatibility': 'UNKNOWN', 'fields': self.fields}
        ids = ('Base.Worm', 'Base.Fish', 'Base.Trash', 'Base.Line', 'Base.Hook', 'Base.Rod', 'Base.BrokenRod')
        self.items = {'records': [{'full_type': item} for item in ids]}

    def validate(self):
        return validate_fishing_details({'fishing_details': self.detail,
                                         'fishing_details_sha256': digest(self.detail)}, self.items)

    def test_all_item_roles_resolve(self):
        result = self.validate()
        self.assertEqual(result['fish'], 1)
        self.assertEqual(result['lures'], {'Base.Worm'})
        self.assertEqual(result['unresolved_items'], set())

    def test_unresolved_reference_is_reported_not_guessed(self):
        self.items['records'].pop()
        self.assertEqual(self.validate()['unresolved_items'], {'Base.BrokenRod'})

    def test_lure_index_must_match_categories(self):
        all_node = next(e['value'] for e in self.fields['lure']['entries'] if e['key'] == 'All')
        all_node['entries'][0]['key'] = 'Base.Other'
        with self.assertRaisesRegex(CatalogError, 'differs'): self.validate()

    def test_sparse_list_and_tampering_rejected(self):
        self.fields['fishNet']['entries'][0]['key'] = '2.0'
        with self.assertRaisesRegex(CatalogError, 'Sparse'): self.validate()
        self.fields['fishNet']['entries'][0]['key'] = '1.0'
        proof = {'fishing_details': self.detail, 'fishing_details_sha256': digest(self.detail)}
        self.fields['rods']['entries'][0]['key'] = 'Base.OtherRod'
        with self.assertRaisesRegex(CatalogError, 'hash mismatch'):
            validate_fishing_details(proof, self.items)

    def test_missing_export_and_compatibility_claim_rejected(self):
        with self.assertRaises(CatalogError): validate_fishing_details({}, self.items, required=True)
        self.detail['npc_compatibility'] = 'SUPPORTED'
        with self.assertRaises(CatalogError): self.validate()


if __name__ == '__main__':
    unittest.main()
