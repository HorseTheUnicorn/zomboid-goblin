import unittest

from tests.test_pz_fixing_details import digest
from tests.test_vehicle_requirement_audit import table
from tools.check_pz_catalog import CatalogError, validate_moveable_details


def scalar(value):
    return {'type': 'string', 'scalar': value, 'entries': []}


def seq(*values):
    return {'type': 'table', 'scalar': None, 'entries': [
        {'key_type': 'number', 'key': f'{index}.0',
         'value': value if isinstance(value, dict) else scalar(value)}
        for index, value in enumerate(values, 1)]}


class MoveableDetailTests(unittest.TestCase):
    def setUp(self):
        tool = table(items=seq('Base.Hammer'))
        material = table(returnItem='Plank')
        scrap_return = table(returnItem='Base.Nails')
        scrap = table(tools=seq('Base.Hammer'), tools2=seq('Tag.WeldingMask'),
                      returnItems=seq(scrap_return), returnItemsStatic=seq(),
                      unusableItem='Base.UnusableWood')
        part = table(itemType='Base.Plank')
        repair = table(tools=seq('Base.Hammer'), tools2=seq(), parts=seq(part))
        self.fields = dict(sorted({
            'toolDefinitions': table(Hammer=tool),
            'matsDefinitions': table(Wood=seq(material)),
            'scrapDefinitions': table(Wood=scrap),
            'healthDefinitions': table(Wood='1'),
            'repairDefinitions': table(Wood=repair),
            'floorReplaceSprites': seq('floors_interior_tilesandwood_01_0'),
        }.items()))
        self.detail = {'schema_version': 1, 'npc_compatibility': 'UNKNOWN', 'fields': self.fields}
        self.items = {'records': [{'full_type': value} for value in
                                  ('Base.Hammer', 'Base.Plank', 'Base.Nails', 'Base.UnusableWood')]}

    def validate(self):
        return validate_moveable_details({'moveable_details': self.detail,
                                          'moveable_details_sha256': digest(self.detail)}, self.items)

    def test_roles_and_references(self):
        result = self.validate()
        self.assertEqual((result['tools'], result['materials'], result['scrap'], result['repairs']), (1, 1, 1, 1))
        self.assertEqual(result['tags'], {'Tag.WeldingMask'})
        self.assertEqual(result['alias_resolutions'], {'Plank': 'Base.Plank'})
        self.assertEqual(result['unresolved_items'], set())

    def test_unresolved_is_reported(self):
        self.items['records'].pop()
        self.assertEqual(self.validate()['unresolved_items'], {'Base.UnusableWood'})

    def test_sparse_list_and_hash_tampering_rejected(self):
        self.fields['floorReplaceSprites']['entries'][0]['key'] = '2.0'
        with self.assertRaisesRegex(CatalogError, 'Sparse'): self.validate()
        self.fields['floorReplaceSprites']['entries'][0]['key'] = '1.0'
        proof = {'moveable_details': self.detail, 'moveable_details_sha256': digest(self.detail)}
        self.fields['healthDefinitions']['entries'][0]['key'] = 'Changed'
        with self.assertRaisesRegex(CatalogError, 'hash mismatch'):
            validate_moveable_details(proof, self.items)

    def test_missing_and_compatibility_claim_rejected(self):
        with self.assertRaises(CatalogError): validate_moveable_details({}, self.items, required=True)
        self.detail['npc_compatibility'] = 'SUPPORTED'
        with self.assertRaises(CatalogError): self.validate()


if __name__ == '__main__':
    unittest.main()
