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


def validate_physical_evidence(record, root):
    """Accept only the narrow, structured review format implemented here.

    Free-text multiplayer_evidence remains descriptive and is never sufficient.
    New capability kinds must add their own field-level review before they can be
    marked complete or engine-tested.
    """
    label = record["id"]
    review = record.get("physical_evidence_review")
    if not isinstance(review, dict) or review.get("kind") != "MILESTONE_1_FOLLOW":
        raise CatalogError(f"{label}: physical evidence review required")
    if label != "FOLLOW":
        raise CatalogError(f"{label}: unsupported physical evidence review kind")
    path = review.get("path")
    if not isinstance(path, str) or not path:
        raise CatalogError(f"{label}: physical evidence review path missing")
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root) or not resolved.is_file():
        raise CatalogError(f"{label}: physical evidence review missing or outside workspace")
    evidence = read_catalog(resolved)
    milestone = evidence.get("milestone_1")
    required = {
        "stable follow slots", "native follow investigation",
        "expanded work approach search", "staged stuck recovery",
        "navigation telemetry", "temporary route blacklist",
    }
    scenarios = {
        "follow through open terrain", "follow through house doorway",
        "follow around furniture", "follow upstairs/downstairs",
        "owner runs through building", "work target surrounded on some sides",
        "path fails and recovers without teleport", "two players plus two Goblins",
    }
    if (evidence.get("schema_version") != 1 or not isinstance(milestone, dict)
            or milestone.get("result") != "pass"
            or not required <= set(milestone.get("requirements", []))
            or not scenarios <= set(milestone.get("live_scenarios_accepted", []))):
        raise CatalogError(f"{label}: Milestone 1 acceptance is incomplete")
    clients = evidence.get("clients")
    if (not isinstance(clients, list) or len(clients) < 2
            or any(client.get("ordinary_executable") is not True
                   or client.get("storm") is not False for client in clients[:2])
            or len({client.get("goblin_id") for client in clients[:2]}) != 2):
        raise CatalogError(f"{label}: two-client/two-Goblin evidence is incomplete")
    required_passes = (
        "closed_door_follow", "durable_radius_two_staging",
        "open_terrain_running_follow", "native_no_progress_recovery",
        "native_simulation_ownership_handoff", "furniture_detour",
        "stair_follow", "running_owner_building_follow",
    )
    if any(not isinstance(evidence.get(name), dict)
           or evidence[name].get("result") != "pass" for name in required_passes):
        raise CatalogError(f"{label}: required physical scenario did not pass")
    running = evidence["open_terrain_running_follow"]
    recovery = evidence["native_no_progress_recovery"]
    handoff = evidence["native_simulation_ownership_handoff"]
    furniture = evidence["furniture_detour"]
    stairs = evidence["stair_follow"]
    building = evidence["running_owner_building_follow"]
    ascent_z = [row.get("actor", {}).get("z") for row in stairs.get("ascent_observations", [])]
    descent_z = [row.get("actor", {}).get("z") for row in stairs.get("descent_owner_client_trace", [])]
    route_states = {row.get("native_state") for row in building.get("actor_route", [])}
    if (running.get("teleport_after_measurement") is not False
            or recovery.get("native_repath_attempts") != 1
            or recovery.get("teleport") is not False
            or handoff.get("staging", {}).get("ownership_write") is not False
            or handoff.get("staging", {}).get("goblin_teleport") is not False
            or furniture.get("occupied_obstacle_square") is not False
            or furniture.get("follow_rejoin_during_measurement") is not False
            or furniture.get("goblin_position_write") is not False
            or stairs.get("follow_rejoin_during_measurement") is not False
            or stairs.get("goblin_position_write") is not False
            or 0.0 not in ascent_z or 1.0 not in ascent_z
            or not any(isinstance(z, (int, float)) and 0 < z < 1 for z in descent_z)
            or building.get("owner_run", {}).get("delta_tiles", 0) < 10
            or building.get("final_gap_tiles", 999) > 4
            or not {"ClimbThroughWindowState", "PathFindState"} <= route_states
            or building.get("follow_rejoin_during_measurement") is not False
            or building.get("goblin_position_write") is not False):
        raise CatalogError(f"{label}: structured physical evidence constraints failed")


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
    toolkit = inventory.get("permanent_toolkit")
    if inventory_status == complete_status:
        if not isinstance(toolkit, dict):
            raise CatalogError("Complete capability inventory lacks permanent toolkit catalog")
        categories = toolkit.get("categories")
        if not isinstance(categories, dict) or not categories:
            raise CatalogError("Permanent toolkit categories missing")
        toolkit_ids = []
        for category, item_types in categories.items():
            if not isinstance(category, str) or not category:
                raise CatalogError("Invalid permanent toolkit category")
            toolkit_ids.extend(names(item_types, f"{category} toolkit IDs"))
        if len(toolkit_ids) != len(set(toolkit_ids)):
            raise CatalogError("Permanent toolkit IDs overlap across categories")
        for item in toolkit_ids:
            installed = item_index.get(item)
            if not installed or installed.get("enabled") is not True or installed.get("obsolete") is not False:
                raise CatalogError(f"Permanent toolkit item is unavailable: {item}")
        consumables = names(toolkit.get("excluded_consumables"), "excluded toolkit consumables")
        if set(toolkit_ids) & consumables:
            raise CatalogError("Permanent toolkit contains an excluded consumable")
        source = toolkit.get("source")
        if not isinstance(source, dict) or not source.get("path") or not source.get("sha256"):
            raise CatalogError("Permanent toolkit source evidence missing")
        resolved = (root / source["path"]).resolve()
        if not resolved.is_relative_to(root) or not resolved.is_file():
            raise CatalogError("Permanent toolkit source missing or outside workspace")
        if hashlib.sha256(resolved.read_bytes()).hexdigest() != source["sha256"]:
            raise CatalogError("Permanent toolkit source changed since audit")
    for record in records:
        label = record["id"]
        if record.get("origin") not in ("existing", "proposed"):
            raise CatalogError(f"{label}: invalid origin")
        if type(record.get("complete")) is not bool:
            raise CatalogError(f"{label}: completion must be boolean")
        evidence = record.get("multiplayer_evidence")
        if not isinstance(evidence, list):
            raise CatalogError(f"{label}: multiplayer evidence must be explicit")
        if record["complete"] or label in tested:
            validate_physical_evidence(record, root)
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
    print("Only capabilities with a supported structured physical-evidence review are certified complete or engine-tested.")


if __name__ == "__main__":
    main()
