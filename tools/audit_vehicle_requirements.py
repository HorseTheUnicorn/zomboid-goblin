"""Resolve captured vehicle service references; never certify actor compatibility."""
import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

from tools.check_pz_catalog import read_catalog, validate_vehicle_details


def audit(proof, items):
    validate_vehicle_details(proof, items, required=True, require_tables=True)
    enabled = {r['full_type']: r for r in items['records']
               if r.get('enabled') is True and r.get('obsolete') is False}
    tags = defaultdict(list)
    for identifier, record in enabled.items():
        for tag in record.get('tags', []):
            tags[tag].append(identifier)
    values = defaultdict(Counter)
    missing_parts, missing_tests = [], []
    count = 0

    def fields(node):
        return {e['key']: e['value'] for e in node['entries'] if e['key_type'] == 'string'}

    def collect(node):
        for entry in node['entries']:
            value = entry['value']
            if value['type'] == 'table':
                collect(value)
            elif entry['key_type'] == 'string':
                values[entry['key']][value['scalar']] += 1

    for vehicle in proof['vehicle_details']['records']:
        part_ids = {p['id'] for p in vehicle['parts']}
        for part in vehicle['parts']:
            for operation in ('install', 'uninstall'):
                table = part['tables'].get(operation)
                if table is None:
                    continue
                count += 1
                collect(table)
                table_fields = fields(table)
                context = {'vehicle': vehicle['id'], 'part': part['id'], 'operation': operation}
                if 'test' not in table_fields:
                    missing_tests.append(context)
                for key in ('requireInstalled', 'requireUninstalled', 'door'):
                    value = table_fields.get(key)
                    if value is None:
                        continue
                    if value['type'] != 'string':
                        raise ValueError(f'Non-string prerequisite: {context} {key}')
                    for target in value['scalar'].split(';'):
                        if target not in part_ids:
                            missing_parts.append({**context, 'field': key, 'target': target})
    exact = {value: {'occurrences': n, 'resolved': value in enabled}
             for value, n in sorted(values['type'].items())}
    tag_results = {}
    for expression, n in sorted(values['tags'].items()):
        alternatives = {tag: sorted(tags.get(tag, [])) for tag in expression.split(';')}
        tag_results[expression] = {'occurrences': n, 'alternatives': alternatives,
                                   'has_installed_match': any(alternatives.values())}
    return {
        'scope': 'captured_definition_references_only',
        'source_vehicle_details_sha256': proof['vehicle_details_sha256'],
        'operation_tables': count, 'exact_item_requirements': exact,
        'tag_requirements': tag_results,
        'knowledge_names_not_craft_recipe_ids': dict(sorted(values['recipes'].items())),
        'declared_skills_not_execution_gates': dict(sorted(values['skills'].items())),
        'test_callbacks': dict(sorted(values['test'].items())),
        'completion_callbacks': dict(sorted(values['complete'].items())),
        'missing_test_fields': missing_tests, 'absent_part_references': missing_parts,
        'npc_compatibility': 'UNVERIFIED',
        'limitations': [
            'Tag matches do not prove runtime item condition or availability',
            'Knowledge names require native recipe-knowledge lookup, not CraftRecipe inference',
            'An absent requireUninstalled target may be permitted by native logic; not an automatic defect',
            'Native callback code and Workshop overrides need separate actor/authority review',
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
