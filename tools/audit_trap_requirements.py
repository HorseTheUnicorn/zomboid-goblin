"""Resolve loaded trapping references without claiming native actor support."""
import argparse
import json
from pathlib import Path

from tools.check_pz_catalog import read_catalog, validate_survival_details


def table(node):
    if node.get('type') != 'table':
        raise ValueError('expected typed table')
    return {entry['key']: entry['value'] for entry in node['entries']}


def scalar(node):
    if node.get('type') not in ('string', 'number', 'boolean'):
        raise ValueError('expected scalar')
    return node['scalar']


def sequence(node):
    values = table(node)
    ordered = []
    for index in range(1, len(values) + 1):
        key = f'{index}.0'
        if key not in values:
            raise ValueError('sparse numeric table')
        ordered.append(values[key])
    return ordered


def audit(proof, items):
    validate_survival_details(proof, items, required=True)
    enabled = {r['full_type'] for r in items['records']
               if r.get('enabled') is True and r.get('obsolete') is False}
    detail = proof['survival_details']
    trap_rows, animal_rows = [], []
    references = set()
    for node in sequence(detail['traps']):
        fields = table(node)
        trap_type = scalar(fields['type'])
        references.add(trap_type)
        destroyed = fields.get('destroyItem')
        destroyed_ids = []
        if destroyed is not None:
            values = sequence(destroyed) if destroyed['type'] == 'table' else [destroyed]
            destroyed_ids = [scalar(value) for value in values]
            references.update(destroyed_ids)
        trap_rows.append({'type': trap_type, 'destroy_items': destroyed_ids})
    trap_types = {row['type'] for row in trap_rows}
    bait_ids, catch_items = set(), set()
    for node in sequence(detail['animals']):
        fields = table(node)
        animal_type = scalar(fields['type'])
        item = scalar(fields['item']) if 'item' in fields else None
        if item:
            catch_items.add(item); references.add(item)
        baits = set(table(fields.get('baits', {'type': 'table', 'entries': []})))
        traps = set(table(fields.get('traps', {'type': 'table', 'entries': []})))
        bait_ids.update(baits); references.update(baits); references.update(traps)
        animal_rows.append({'type': animal_type, 'item': item,
                            'baits': sorted(baits), 'traps': sorted(traps),
                            'unknown_traps': sorted(traps - trap_types)})
    return {
        'scope': 'captured_trapping_definitions_only',
        'source_survival_details_sha256': proof['survival_details_sha256'],
        'traps': trap_rows, 'animals': animal_rows,
        'bait_item_ids': sorted(bait_ids), 'catch_item_ids': sorted(catch_items),
        'resolved_enabled_nonobsolete': sorted(references & enabled),
        'unavailable_item_ids': sorted(references - enabled),
        'npc_compatibility': 'UNVERIFIED',
        'limitations': [
            'Alive animal type and breed names are not item identifiers',
            'Base.Animal and animal-corpse construction are native output paths, not declared animal.item values',
            'Registry resolution does not prove bait eligibility, mutation order, actor support or replication',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, default=Path('reference'))
    args = parser.parse_args()
    print(json.dumps(audit(read_catalog(args.reference / 'pz-runtime-fingerprint.json'),
                           read_catalog(args.reference / 'pz-items.json')), indent=2))


if __name__ == '__main__':
    main()
