"""Check inventory consistency, not physical ability acceptance.

Unknown compatibility is legitimate during Section 31. This tool rejects stale
source hashes, nonexistent item IDs and unsupported completion claims; passing it
does not establish that the inventory is exhaustive or the game behavior works.
"""
import argparse
import hashlib
import json
from pathlib import Path

from tools.check_pz_catalog import CatalogError, read_catalog


# Section 31.9: structural coverage only. Values still require source review;
# a filled field is not evidence of correctness or engine compatibility.
EVIDENCE_FIELDS = {
    "semantic_arguments": ("semantic_arguments",),
    "target_class": ("target_class",),
    "native_api": ("native_api",),
    "public_documentation_url": ("public_documentation_url", "public_documentation_urls",
                                 "native_api.public_documentation_url"),
    "authority": ("authority",),
    "item_recipe_resolution": ("item_recipe_resolution",),
    "permission_checks": ("permission_checks",),
    "completion_requirements": ("completion_evidence_required",),
    "replication_save_strategy": ("replication_save_strategy",),
    "reconciliation_strategy": ("reconciliation_strategy", "rollback_reconciliation"),
    "verified_versions": ("verified_versions", "verified_game", "verified_storm"),
    "unit_test_ids": ("unit_test_ids", "unit_tests"),
    "multiplayer_evidence": ("multiplayer_evidence",),
}


def evidence_gaps(inventory):
    """Report missing structured evidence without certifying present values.

    Do not infer evidence from prose limitations, item existence or sources.
    Empty evidence is legitimate for proposed actions but remains a gap.
    """
    def present(value):
        if isinstance(value, str):
            return bool(value.strip())
        return isinstance(value, (dict, list)) and bool(value)

    def nested(record, path):
        value = record
        for part in path.split('.'):
            if not isinstance(value, dict):
                return None
            value = value.get(part)
        return value

    records = []
    counts = {field: 0 for field in EVIDENCE_FIELDS}
    for record in inventory["capabilities"]:
        missing = [field for field, aliases in EVIDENCE_FIELDS.items()
                   if not any(present(nested(record, alias)) for alias in aliases)]
        for field in missing:
            counts[field] += 1
        records.append({"id": record["id"], "origin": record["origin"],
                        "missing_fields": missing})
    return {"audit_kind": "structural_evidence_coverage_only",
            "certifies_completion": False, "record_count": len(records),
            "missing_counts": counts, "records": records}


def names(value, label):
    if not isinstance(value, list) or any(not isinstance(x, str) or not x for x in value):
        raise CatalogError(f"{label} must contain nonempty strings")
    if len(value) != len(set(value)):
        raise CatalogError(f"Duplicate {label}")
    return set(value)


def validate_inventory(inventory, commands, items, root):
    if inventory.get("schema_version") != 1 or commands.get("schema_version") != 1:
        raise CatalogError("Unsupported inventory schema")
    records = inventory.get("capabilities")
    if not isinstance(records, list) or not records:
        raise CatalogError("Capability records missing")
    if any(not isinstance(r, dict) for r in records):
        raise CatalogError("Capability record must be an object")
    ids = names([r.get("id") for r in records], "capability IDs")
    existing = names(inventory.get("remaining_existing_inventory"), "remaining existing IDs")
    proposed = names(inventory.get("remaining_proposed_inventory"), "remaining proposed IDs")
    if ids & (existing | proposed) or existing & proposed:
        raise CatalogError("Audited/remaining inventory IDs overlap")
    inventory_status = inventory.get("inventory_status")
    complete_status = "complete_inventory_with_explicit_unimplemented_and_unverified_gaps"
    if inventory_status == complete_status:
        if existing or proposed:
            raise CatalogError("Complete capability inventory still has remaining IDs")
        gaps = evidence_gaps(inventory)["missing_counts"]
        proof_only = {"unit_test_ids", "multiplayer_evidence"}
        uncovered = {field: count for field, count in gaps.items()
                     if field not in proof_only and count}
        if uncovered:
            raise CatalogError(f"Complete capability inventory has structural gaps: {uncovered}")
    elif inventory_status not in (None, "partial"):
        raise CatalogError("Unknown capability inventory status")
    tested = names(inventory.get("engine_tested_capabilities"), "engine-tested IDs")
    if not tested <= ids:
        raise CatalogError("Unknown engine-tested capability")
    item_index = {r["full_type"]: r for r in items["records"]}
    root = Path(root).resolve()
    for record in records:
        label = record["id"]
        if record.get("origin") not in ("existing", "proposed"):
            raise CatalogError(f"{label}: invalid origin")
        if type(record.get("complete")) is not bool:
            raise CatalogError(f"{label}: completion must be boolean")
        evidence = record.get("multiplayer_evidence")
        if not isinstance(evidence, list):
            raise CatalogError(f"{label}: multiplayer evidence must be explicit")
        # Evidence format/acceptance review is not implemented yet. Do not accept
        # free-text claims as physical proof, even if somebody adds a nonempty list.
        if record["complete"] or label in tested:
            raise CatalogError(f"{label}: physical evidence review required; this checker cannot certify completion")
        for item in names(record.get("required_items", []), f"{label} required items"):
            installed = item_index.get(item)
            if not installed or installed.get("enabled") is not True or installed.get("obsolete") is not False:
                raise CatalogError(f"{label}: unavailable required item {item}")
        sources = record.get("sources")
        if not isinstance(sources, list) or not sources:
            raise CatalogError(f"{label}: source evidence missing")
        for source in sources:
            if not isinstance(source, dict):
                raise CatalogError(f"{label}: invalid source record")
            path = source.get("path")
            if path is None:  # Captured installed paths are not workspace paths.
                if not source.get("installed_path"):
                    raise CatalogError(f"{label}: source path missing")
                continue
            if not isinstance(path, str) or not path:
                raise CatalogError(f"{label}: invalid source path")
            resolved = (root / path).resolve()
            if not resolved.is_relative_to(root) or not resolved.is_file():
                raise CatalogError(f"{label}: source missing or outside workspace: {path}")
            if "sha256" in source and hashlib.sha256(resolved.read_bytes()).hexdigest() != source["sha256"]:
                raise CatalogError(f"{label}: source changed since audit: {path}")
    surface = commands.get("existing_goblin_chat", {}).get("commands")
    if not isinstance(surface, list):
        raise CatalogError("Existing command inventory missing")
    names([c.get("command") for c in surface], "existing commands")
    # Catalog membership is not implementation: proposed records now have IDs
    # too, but must never validate an advertised existing chat task.
    existing_ids = {record["id"] for record in records if record["origin"] == "existing"}
    for command in surface:
        task = command.get("task")
        if task is not None and task not in existing_ids | existing:
            raise CatalogError(f"Existing command maps to unknown/proposed task: {task}")
        if not command.get("handler"):
            raise CatalogError(f"Command handler missing: {command['command']}")
    proposed_commands = commands.get("proposed_goblin_chat")
    if not isinstance(proposed_commands, list):
        raise CatalogError("Proposed command inventory missing")
    names([command.get("command") for command in proposed_commands], "proposed commands")
    if any(command.get("registered") is not False for command in proposed_commands):
        raise CatalogError("Proposed command must remain explicitly unregistered")

    # The repository artifact may declare its inventory structurally complete
    # while every physical ability remains unverified. Validate that declaration
    # without converting it into an engine-acceptance claim.
    command_status = commands.get("inventory_status")
    if command_status == complete_status:
        natural = commands.get("existing_natural_language_chat")
        if not isinstance(natural, dict) or not isinstance(natural.get("routes"), list) or not natural["routes"]:
            raise CatalogError("Complete command inventory lacks natural-language routes")
        source = natural.get("source")
        if not isinstance(source, dict) or not source.get("path") or not source.get("sha256"):
            raise CatalogError("Natural-language source evidence missing")
        resolved = (root / source["path"]).resolve()
        if not resolved.is_relative_to(root) or not resolved.is_file():
            raise CatalogError("Natural-language source missing or outside workspace")
        if hashlib.sha256(resolved.read_bytes()).hexdigest() != source["sha256"]:
            raise CatalogError("Natural-language source changed since audit")
        for route in natural["routes"]:
            if not isinstance(route, dict) or route.get("task") not in existing_ids or not route.get("example"):
                raise CatalogError("Natural-language route maps to unknown/proposed task")
        qwen = commands.get("qwen_intent_transport")
        if not isinstance(qwen, dict):
            raise CatalogError("Complete command inventory lacks Qwen transport boundary")
        names(qwen.get("chat_generation_actions"), "Qwen chat generation actions")
        names(qwen.get("offline_actions"), "Qwen offline actions")
        rcon = commands.get("administrative_server_rcon")
        if not isinstance(rcon, dict) or not str(rcon.get("inventory_status", "")).startswith("audited_"):
            raise CatalogError("Complete command inventory lacks RCON audit status")
        if not isinstance(rcon.get("commands"), list) or rcon.get("gameplay_callable") is not False:
            raise CatalogError("Invalid RCON command boundary")
    elif command_status not in (None, "partial"):
        raise CatalogError("Unknown command inventory status")
    return len(records), len(existing), len(proposed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--evidence-gaps", action="store_true",
                        help="Print read-only JSON field coverage; never certifies completion")
    args = parser.parse_args()
    try:
        reference = args.root / "reference"
        inventory = read_catalog(reference / "goblin-capabilities.json")
        commands = read_catalog(reference / "goblin-commands.json")
        result = validate_inventory(inventory,
                                    commands,
                                    read_catalog(reference / "pz-items.json"), args.root)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Inventory validation failed: {error}\n")
    if args.evidence_gaps:
        print(json.dumps(evidence_gaps(inventory), indent=2))
        return
    print(f"Consistency checked: {result[0]} records; remaining {result[1]} existing / {result[2]} proposed.")
    if inventory.get("inventory_status", "").startswith("complete_inventory") and commands.get("inventory_status", "").startswith("complete_inventory"):
        print("Section 31 catalog/compatibility inventory is structurally complete with explicit proof gaps.")
    print("This does not certify any capability's physical or multiplayer behavior.")


if __name__ == "__main__":
    main()
