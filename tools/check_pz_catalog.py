"""Validate reference exports without treating registry presence as an ability.

Default validation checks artifact structure. --require-runtime additionally
requires non-null build/content provenance. Neither mode proves engine tests.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from datetime import datetime
from pathlib import Path

HASH = re.compile(r"[0-9a-f]{64}\Z")


class CatalogError(ValueError):
    pass


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_catalog(path: Path):
    if path.stat().st_size > 64 * 1024 * 1024:
        raise CatalogError(f"Catalog exceeds 64 MiB: {path.name}")
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys,
                      parse_constant=lambda value: (_ for _ in ()).throw(CatalogError(f"Invalid number: {value}")))


def required(record, fields, label):
    missing = set(fields) - record.keys()
    if missing:
        raise CatalogError(f"{label} missing fields: {', '.join(sorted(missing))}")


def nullable_text(record, fields, label):
    for field in fields:
        if record[field] is not None and not isinstance(record[field], str):
            raise CatalogError(f"{label} invalid text field: {field}")


def validate_io(record, label, is_input):
    fields = {"possible_items", "amount", "max_amount", "variable_amount",
              "resource_type", "possible_fluids", "possible_energies", "resource_evidence"}
    fields |= {"items", "item_tags", "tool", "keep", "destroy"} if is_input else {"chance", "replace_input"}
    if not isinstance(record, dict):
        raise CatalogError(f"{label} must be an object")
    required(record, fields, label)
    nullable_text(record, ["resource_type"], label)
    if not isinstance(record["resource_evidence"], dict) or not record["resource_evidence"]:
        raise CatalogError(f"{label} requires explicit resource evidence")
    for field in ("possible_items", "items", "item_tags") if is_input else ("possible_items",):
        if not isinstance(record[field], list) or any(not isinstance(v, str) or not v for v in record[field]):
            raise CatalogError(f"{label} invalid {field}")
    for field in ("possible_fluids", "possible_energies"):
        if record[field] is not None and not isinstance(record[field], list):
            raise CatalogError(f"{label} invalid resource candidates")
    for field in ("amount", "max_amount", "chance") if not is_input else ("amount", "max_amount"):
        value = record[field]
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise CatalogError(f"{label} invalid {field}")
    for field in ("variable_amount", "tool", "keep", "destroy") if is_input else ("variable_amount", "replace_input"):
        if type(record[field]) is not bool:
            raise CatalogError(f"{label} invalid {field}")


def validate_records(catalog, key, require_runtime=False, runtime_proof=None):
    if not isinstance(catalog, dict) or type(catalog.get("schema_version")) is not int or catalog["schema_version"] != 1:
        raise CatalogError("Expected schema_version 1 envelope")
    expected_kind = "pz-items" if key == "full_type" else "pz-recipes"
    if catalog.get("kind") != expected_kind:
        raise CatalogError(f"Expected catalog kind {expected_kind}")
    timestamp = catalog.get("export_timestamp")
    try:
        if not isinstance(timestamp, str) or datetime.fromisoformat(timestamp.replace("Z", "+00:00")).utcoffset() is None:
            raise ValueError("missing timezone")
    except ValueError as error:
        raise CatalogError("Expected timezone-aware export timestamp") from error
    records = catalog.get("records")
    if not isinstance(records, list) or not records:
        raise CatalogError("Missing or empty registry records")
    build = catalog.get("game_build")
    fingerprint = catalog.get("enabled_mods_fingerprint")
    if fingerprint is not None and (not isinstance(fingerprint, str) or not HASH.fullmatch(fingerprint)):
        raise CatalogError("Invalid enabled-mod content fingerprint")
    if require_runtime and (not isinstance(build, str) or not build or fingerprint is None):
        raise CatalogError("Runtime provenance incomplete: build/content fingerprint required")
    if require_runtime and runtime_proof is None:
        raise CatalogError("Runtime validation requires the complete fingerprint/export set")
    ids = []
    for record in records:
        if not isinstance(record, dict):
            raise CatalogError("Registry record must be an object")
        identifier = record.get(key)
        if not isinstance(identifier, str) or not identifier or identifier.strip() != identifier:
            raise CatalogError(f"Missing exact {key}")
        if any(ord(character) < 32 for character in identifier):
            raise CatalogError(f"Control character in {key}")
        for field in ("game_build", "enabled_mods_fingerprint", "export_timestamp"):
            if field not in record or record[field] != catalog.get(field):
                raise CatalogError(f"Record/envelope provenance mismatch: {identifier} {field}")
        tags = record.get("tags")
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags) or tags != sorted(set(tags)):
            raise CatalogError(f"Tags must be sorted unique strings: {identifier}")
        if key == "full_type":
            required(record, {"display_name", "display_category", "weight", "source_mod", "source_file",
                              "reusable_tool_roles", "consumable_state", "evidence", "lookup_by_id", "enabled", "obsolete"}, identifier)
            nullable_text(record, ("display_name", "display_category", "source_mod", "source_file"), identifier)
            if not isinstance(record["evidence"], dict) or not record["evidence"]:
                raise CatalogError(f"Missing item evidence: {identifier}")
            if type(record["lookup_by_id"]) is not bool or record["lookup_by_id"] is not True:
                raise CatalogError(f"Unresolved item lookup: {identifier}")
            for flag in ("enabled", "obsolete"):
                if type(record[flag]) is not bool:
                    raise CatalogError(f"Invalid item flag: {identifier} {flag}")
            weight = record.get("weight")
            if weight is not None and (type(weight) not in (float, int) or not math.isfinite(weight) or weight < 0):
                raise CatalogError(f"Invalid item weight: {identifier}")
        else:
            required(record, {"name", "mod_id", "enabled", "obsolete", "requires_player", "inputs", "outputs",
                              "lookup_key", "lookup_by_id", "lookup_by_name", "lookup_evidence", "lua_callbacks", "npc_compatibility"}, identifier)
            nullable_text(record, ("name", "mod_id", "lookup_key", "lookup_evidence"), identifier)
            for flag in ("enabled", "obsolete", "requires_player"):
                if type(record[flag]) is not bool:
                    raise CatalogError(f"Invalid recipe flag: {identifier} {flag}")
            if record["npc_compatibility"] not in ("UNKNOWN", "UNSUPPORTED"):
                raise CatalogError("Registry export cannot assert NPC recipe compatibility")
            if not record["lookup_key"] or not (record["lookup_by_id"] is True or record["lookup_by_name"] is True):
                raise CatalogError(f"Unresolved recipe lookup: {identifier}")
            for field in ("inputs", "outputs"):
                if not isinstance(record[field], list):
                    raise CatalogError(f"Recipe {field} must be a list")
                for index, io in enumerate(record[field]):
                    validate_io(io, f"{identifier}.{field}[{index}]", field == "inputs")
        # Registry export must never award physical acceptance by itself.
        if record.get("engine_tested") is True:
            raise CatalogError("Registry records cannot assert engine acceptance")
        ids.append(identifier)
    if ids != sorted(set(ids)):
        raise CatalogError(f"{key} entries must be sorted and unique")
    return set(ids)


def validate_export_set(items, recipes, proof, raw_files, require_runtime=False):
    if not isinstance(proof, dict) or proof.get("kind") != "pz-runtime-fingerprint" or proof.get("schema_version") != 1:
        raise CatalogError("Missing runtime fingerprint commit artifact")
    hashes = proof.get("export_files_sha256")
    if not isinstance(hashes, dict) or set(hashes) != {"pz-items.json", "pz-recipes.json"}:
        raise CatalogError("Fingerprint must bind both exact exported files")
    if set(raw_files) != set(hashes):
        raise CatalogError("Both exported byte payloads are required")
    for filename, payload in raw_files.items():
        if hashlib.sha256(payload).hexdigest() != hashes.get(filename):
            raise CatalogError(f"Export content hash mismatch: {filename}")
        expected = items if filename == "pz-items.json" else recipes
        if json.loads(payload, object_pairs_hook=reject_duplicate_keys) != expected:
            raise CatalogError(f"Parsed catalog differs from verified bytes: {filename}")
    for field in ("game_build", "enabled_mods_fingerprint", "export_timestamp"):
        if items.get(field) != recipes.get(field) or items.get(field) != proof.get(field):
            raise CatalogError(f"Catalogs are from different exports: {field}")
    if require_runtime:
        if proof.get("enabled_mods_fingerprint_status") != "CONTENT_VERIFIED":
            raise CatalogError("Effective enabled-mod content proof is incomplete")
        validate_content_manifest(proof)
    validate_supplemental_catalog(proof)
    validate_fixing_details(proof, items)
    validate_evolved_details(proof, items)
    validate_crop_details(proof, items)
    validate_vehicle_details(proof, items)
    validate_survival_details(proof, items)
    validate_fishing_details(proof, items)
    return (validate_records(items, "full_type", require_runtime, proof),
            validate_records(recipes, "recipe_id", require_runtime, proof))


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False).encode("utf-8")).hexdigest()


def validate_supplemental_catalog(proof, required=False):
    """Validate the identity-only extension; absence is allowed for older exports."""
    catalog = proof.get("supplemental_catalog")
    digest = proof.get("supplemental_catalog_sha256")
    if catalog is None and digest is None and not required:
        return set()
    if not isinstance(catalog, dict) or set(catalog) != {
            "schema_version", "scope", "npc_compatibility", "records"}:
        raise CatalogError("Supplemental catalog missing or malformed")
    if (type(catalog["schema_version"]) is not int or catalog["schema_version"] != 1
            or catalog["scope"] != "identity_only" or catalog["npc_compatibility"] != "UNKNOWN"):
        raise CatalogError("Supplemental identity export cannot claim NPC compatibility")
    records = catalog["records"]
    if not isinstance(records, list) or len(records) > 250_000:
        raise CatalogError("Invalid supplemental record count")
    ids, normalized = set(), []
    for record in records:
        if not isinstance(record, dict) or set(record) != {"kind", "id", "obsolete"}:
            raise CatalogError("Malformed supplemental identity")
        if (record["kind"] not in ("fixing", "evolved_recipe")
                or not isinstance(record["id"], str) or not record["id"].strip()
                or type(record["obsolete"]) is not bool):
            raise CatalogError("Invalid supplemental identity fields")
        key = (record["kind"], record["id"])
        if key in ids:
            raise CatalogError("Duplicate supplemental identity")
        ids.add(key)
        normalized.append({"kind": record["kind"], "id": record["id"], "obsolete": record["obsolete"]})
    # Match Java's explicit field order, independent of parsed object key order.
    canonical = {"schema_version": 1, "scope": "identity_only", "npc_compatibility": "UNKNOWN",
                 "records": normalized}
    actual = hashlib.sha256(json.dumps(canonical, separators=(",", ":"),
                                      ensure_ascii=False).encode("utf-8")).hexdigest()
    if digest != actual:
        raise CatalogError("Supplemental catalog content hash mismatch")
    return ids


def validate_fixing_details(proof, items, required=False):
    detail, digest = proof.get("fixing_details"), proof.get("fixing_details_sha256")
    if detail is None and digest is None and not required:
        return set()
    if not isinstance(detail, dict) or set(detail) != {"schema_version", "npc_compatibility", "records"}:
        raise CatalogError("Fixing details missing or malformed")
    if type(detail["schema_version"]) is not int or detail["schema_version"] != 1 or detail["npc_compatibility"] != "UNKNOWN":
        raise CatalogError("Invalid fixing detail schema or compatibility claim")
    registered = {id_ for kind, id_ in validate_supplemental_catalog(proof, required=True) if kind == "fixing"}
    item_index = {record["full_type"]: record for record in items["records"]}

    def reference(value):
        if not isinstance(value, dict) or set(value) != {"declared", "resolved", "obsolete"}:
            raise CatalogError("Malformed fixing item reference")
        if not isinstance(value["declared"], str) or not value["declared"].strip() or type(value["obsolete"]) is not bool:
            raise CatalogError("Invalid fixing item reference")
        resolved = value["resolved"]
        if resolved is not None:
            if not isinstance(resolved, str) or resolved not in item_index:
                raise CatalogError("Unknown resolved fixing item")
            if value["obsolete"] != item_index[resolved]["obsolete"]:
                raise CatalogError("Fixing item obsolete status mismatch")
        elif value["obsolete"]:
            raise CatalogError("Unresolved item cannot assert obsolete status")
        return {key: value[key] for key in ("declared", "resolved", "obsolete")}

    def material(value):
        if not isinstance(value, dict) or set(value) != {"item", "uses", "skills"}:
            raise CatalogError("Malformed fixer material")
        if type(value["uses"]) is not int or not isinstance(value["skills"], list) or len(value["skills"]) > 1000:
            raise CatalogError("Invalid fixer uses/skills")
        skills = []
        for skill in value["skills"]:
            if (not isinstance(skill, dict) or set(skill) != {"name", "level"}
                    or not isinstance(skill["name"], str) or not skill["name"].strip()
                    or type(skill["level"]) is not int):
                raise CatalogError("Invalid fixer skill")
            skills.append({"name": skill["name"], "level": skill["level"]})
        return {"item": reference(value["item"]), "uses": value["uses"], "skills": skills}

    records = detail["records"]
    if not isinstance(records, list) or len(records) > 250_000:
        raise CatalogError("Invalid fixing detail record count")
    seen, normalized = set(), []
    for record in records:
        if not isinstance(record, dict) or set(record) != {"id", "targets", "alternatives", "global", "condition_modifier"}:
            raise CatalogError("Malformed fixing detail record")
        id_ = record["id"]
        if not isinstance(id_, str) or id_ not in registered or id_ in seen:
            raise CatalogError("Unknown/duplicate fixing detail identity")
        seen.add(id_)
        for field in ("targets", "alternatives"):
            if not isinstance(record[field], list) or len(record[field]) > 10_000:
                raise CatalogError("Invalid fixing requirement list")
        modifier = record["condition_modifier"]
        if not isinstance(modifier, str):
            raise CatalogError("Fixing modifier must preserve Java float text")
        try:
            finite = math.isfinite(float(modifier))
        except ValueError:
            finite = False
        if not finite:
            raise CatalogError("Invalid fixing modifier")
        normalized.append({"id": id_, "targets": [reference(v) for v in record["targets"]],
                           "alternatives": [material(v) for v in record["alternatives"]],
                           "global": None if record["global"] is None else material(record["global"]),
                           "condition_modifier": modifier})
    if seen != registered:
        raise CatalogError("Fixing details omit registered definitions")
    canonical = {"schema_version": 1, "npc_compatibility": "UNKNOWN", "records": normalized}
    actual = hashlib.sha256(json.dumps(canonical, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    if digest != actual:
        raise CatalogError("Fixing details content hash mismatch")
    return seen


def validate_evolved_details(proof, items, required=False):
    detail, digest = proof.get("evolved_details"), proof.get("evolved_details_sha256")
    if detail is None and digest is None and not required:
        return set()
    if not isinstance(detail, dict) or set(detail) != {"schema_version", "npc_compatibility", "records"}:
        raise CatalogError("Evolved details missing or malformed")
    if type(detail["schema_version"]) is not int or detail["schema_version"] != 1 or detail["npc_compatibility"] != "UNKNOWN":
        raise CatalogError("Invalid evolved schema or compatibility claim")
    expected = {id_ for kind, id_ in validate_supplemental_catalog(proof, required=True) if kind == "evolved_recipe"}
    item_index = {record["full_type"]: record for record in items["records"]}

    def reference(value):
        if not isinstance(value, dict) or set(value) != {"declared", "resolved", "obsolete"}:
            raise CatalogError("Malformed evolved item reference")
        if not isinstance(value["declared"], str) or not value["declared"].strip() or type(value["obsolete"]) is not bool:
            raise CatalogError("Invalid evolved item reference")
        resolved = value["resolved"]
        if resolved is not None:
            if not isinstance(resolved, str) or resolved not in item_index or value["obsolete"] != item_index[resolved]["obsolete"]:
                raise CatalogError("Evolved item resolution mismatch")
        elif value["obsolete"]:
            raise CatalogError("Unresolved evolved item marked obsolete")
        return {key: value[key] for key in ("declared", "resolved", "obsolete")}

    records = detail["records"]
    if not isinstance(records, list) or len(records) > 250_000:
        raise CatalogError("Invalid evolved detail count")
    seen, normalized = set(), []
    for record in records:
        keys = {"id", "base", "result", "max_items", "minimum_water", "cookable", "ingredients"}
        if not isinstance(record, dict) or set(record) != keys:
            raise CatalogError("Malformed evolved detail")
        id_ = record["id"]
        if not isinstance(id_, str) or id_ not in expected or id_ in seen:
            raise CatalogError("Unknown/duplicate evolved identity")
        seen.add(id_)
        if type(record["max_items"]) is not int or type(record["cookable"]) is not bool:
            raise CatalogError("Invalid evolved limit/flag")
        water = record["minimum_water"]
        try:
            finite = isinstance(water, str) and math.isfinite(float(water))
        except ValueError:
            finite = False
        if not finite:
            raise CatalogError("Invalid evolved minimum water")
        raw = record["ingredients"]
        if not isinstance(raw, list) or len(raw) > 10_000:
            raise CatalogError("Invalid evolved ingredient count")
        ingredients, ingredient_ids = [], set()
        for entry in raw:
            if not isinstance(entry, dict) or set(entry) != {"item", "use", "cooked"}:
                raise CatalogError("Malformed evolved ingredient")
            item = reference(entry["item"])
            if item["declared"] in ingredient_ids:
                raise CatalogError("Duplicate evolved ingredient")
            ingredient_ids.add(item["declared"])
            if ((entry["use"] is not None and type(entry["use"]) is not int)
                    or (entry["cooked"] is not None and type(entry["cooked"]) is not bool)):
                raise CatalogError("Invalid evolved ingredient use/cooked")
            ingredients.append({"item": item, "use": entry["use"], "cooked": entry["cooked"]})
        normalized.append({"id": id_, "base": None if record["base"] is None else reference(record["base"]),
                           "result": None if record["result"] is None else reference(record["result"]),
                           "max_items": record["max_items"], "minimum_water": water,
                           "cookable": record["cookable"], "ingredients": ingredients})
    if seen != expected:
        raise CatalogError("Evolved details omit registered recipes")
    canonical = {"schema_version": 1, "npc_compatibility": "UNKNOWN", "records": normalized}
    actual = hashlib.sha256(json.dumps(canonical, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    if actual != digest:
        raise CatalogError("Evolved details hash mismatch")
    return seen


def validate_crop_details(proof, items, required=False):
    detail, digest = proof.get("crop_details"), proof.get("crop_details_sha256")
    if detail is None and digest is None and not required:
        return {"crops": set(), "unresolved_items": set()}
    if not isinstance(detail, dict) or set(detail) != {"schema_version", "npc_compatibility", "records"}:
        raise CatalogError("Crop details missing or malformed")
    if type(detail["schema_version"]) is not int or detail["schema_version"] != 1 or detail["npc_compatibility"] != "UNKNOWN":
        raise CatalogError("Invalid crop schema or compatibility claim")
    records = detail["records"]
    if not isinstance(records, list) or len(records) > 10_000:
        raise CatalogError("Invalid crop count")
    item_ids = {r["full_type"] for r in items["records"]}
    seen, unresolved, normalized = set(), set(), []
    fields = ("name", "seed_name", "vegetable_name", "produce_extra", "season_recipe", "seed_types")
    for record in records:
        if not isinstance(record, dict) or set(record) != set(fields):
            raise CatalogError("Malformed crop record")
        name = record["name"]
        if not isinstance(name, str) or not name.strip() or name in seen:
            raise CatalogError("Invalid/duplicate crop name")
        seen.add(name)
        for field in fields[1:5]:
            if record[field] is not None and not isinstance(record[field], str):
                raise CatalogError("Crop text field has wrong type")
        seeds = record["seed_types"]
        if seeds is not None and (not isinstance(seeds, list) or len(seeds) > 1000
                                  or any(not isinstance(s, str) or not s.strip() for s in seeds)):
            raise CatalogError("Invalid crop seed list")
        for value in [record[f] for f in fields[1:4]] + (seeds or []):
            if value is not None and value not in item_ids:
                unresolved.add(value)
        normalized.append({field: record[field] for field in fields})
    canonical = {"schema_version": 1, "npc_compatibility": "UNKNOWN", "records": normalized}
    actual = hashlib.sha256(json.dumps(canonical, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    if actual != digest:
        raise CatalogError("Crop details hash mismatch")
    # Unresolved fields are findings, not rewritten guesses or actor eligibility.
    return {"crops": seen, "unresolved_items": unresolved}


def validate_definition_node(node, depth=0, budget=None):
    """Validate typed data without interpreting callbacks, tags or recipe names."""
    budget = [0] if budget is None else budget
    budget[0] += 1
    if depth > 12 or budget[0] > 10_000:
        raise CatalogError("Definition table exceeds bound")
    if not isinstance(node, dict) or set(node) != {"type", "scalar", "entries"}:
        raise CatalogError("Malformed definition node")
    kind, scalar, entries = node["type"], node["scalar"], node["entries"]
    if kind not in ("table", "string", "number", "boolean") or not isinstance(entries, list):
        raise CatalogError("Invalid definition type")
    if kind == "table":
        if scalar is not None:
            raise CatalogError("Table cannot have scalar")
    elif entries or not isinstance(scalar, str) or len(scalar) > 16_384:
        raise CatalogError("Invalid definition scalar")
    if kind == "boolean" and scalar not in ("true", "false"):
        raise CatalogError("Invalid definition boolean")
    if kind == "number":
        try:
            if not math.isfinite(float(scalar)): raise ValueError()
        except (ValueError, OverflowError):
            raise CatalogError("Invalid definition number")
    seen, clean = set(), []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"key_type", "key", "value"}:
            raise CatalogError("Malformed definition entry")
        key_type, key = entry["key_type"], entry["key"]
        if key_type not in ("string", "number") or not isinstance(key, str) or len(key) > 4096:
            raise CatalogError("Invalid definition key")
        if key_type == "number":
            try:
                number = float(key)
                if not math.isfinite(number): raise ValueError()
            except (ValueError, OverflowError):
                raise CatalogError("Invalid numeric definition key")
            identity = (key_type, number)
        else:
            identity = (key_type, key)
        if identity in seen:
            raise CatalogError("Duplicate definition key")
        seen.add(identity)
        clean.append({"key_type": key_type, "key": key,
                      "value": validate_definition_node(entry["value"], depth + 1, budget)})
    return {"type": kind, "scalar": scalar, "entries": clean}


def validate_vehicle_details(proof, items, required=False, require_tables=False):
    detail, digest = proof.get("vehicle_details"), proof.get("vehicle_details_sha256")
    empty = {"vehicles": set(), "parts": 0, "unresolved_items": set()}
    if detail is None and digest is None and not required and not require_tables:
        return empty
    if (not isinstance(detail, dict) or set(detail) != {"schema_version", "npc_compatibility", "records"}
            or type(detail["schema_version"]) is not int or detail["schema_version"] not in (1, 2)
            or detail["npc_compatibility"] != "UNKNOWN"):
        raise CatalogError("Invalid vehicle details schema or compatibility claim")
    version = detail["schema_version"]
    if require_tables and version != 2:
        raise CatalogError("Vehicle requirement tables were not exported")
    records = detail["records"]
    if not isinstance(records, list) or len(records) > 10_000:
        raise CatalogError("Invalid vehicle count")
    item_ids = {r["full_type"] for r in items["records"]}
    seen, unresolved, normalized, count = set(), set(), [], 0
    part_fields = ("id", "parent", "area", "mechanic_area", "item_types", "specific_item",
                   "requires_key", "repair_mechanic", "callbacks", "table_names")
    if version == 2:
        part_fields += ("tables",)
    def identifier(value):
        return isinstance(value, str) and bool(value.strip()) and len(value) <= 4096
    for record in records:
        if not isinstance(record, dict) or set(record) != {"id", "mechanic_type", "engine_repair_level", "parts"}:
            raise CatalogError("Malformed vehicle record")
        if not identifier(record["id"]) or record["id"] in seen:
            raise CatalogError("Invalid/duplicate vehicle ID")
        seen.add(record["id"])
        if any(type(record[f]) is not int for f in ("mechanic_type", "engine_repair_level")):
            raise CatalogError("Invalid vehicle numeric field")
        parts = record["parts"]
        if not isinstance(parts, list) or len(parts) > 10_000:
            raise CatalogError("Invalid vehicle part count")
        part_ids, cleaned = set(), []
        for part in parts:
            if not isinstance(part, dict) or set(part) != set(part_fields):
                raise CatalogError("Malformed vehicle part")
            if not identifier(part["id"]) or part["id"] in part_ids:
                raise CatalogError("Invalid/duplicate part ID")
            part_ids.add(part["id"])
            if any(part[f] is not None and not isinstance(part[f], str) for f in ("parent", "area", "mechanic_area")):
                raise CatalogError("Invalid part text field")
            if any(type(part[f]) is not bool for f in ("specific_item", "requires_key", "repair_mechanic")):
                raise CatalogError("Invalid part flag")
            values = part["item_types"]
            if values is not None and (not isinstance(values, list) or len(values) > 10_000
                                        or any(not identifier(v) for v in values)):
                raise CatalogError("Invalid vehicle item list")
            unresolved.update(v for v in (values or []) if v not in item_ids)
            callbacks, tables = part["callbacks"], part["table_names"]
            if (not isinstance(callbacks, dict) or len(callbacks) > 1000
                    or any(not identifier(k) or not identifier(v) for k, v in callbacks.items())):
                raise CatalogError("Invalid vehicle callback names")
            if (not isinstance(tables, list) or len(tables) > 1000
                    or any(not identifier(v) for v in tables) or len(tables) != len(set(tables))):
                raise CatalogError("Invalid vehicle table names")
            clean = {f: part[f] for f in part_fields}
            clean["callbacks"] = dict(sorted(callbacks.items()))
            if version == 2:
                definitions = part["tables"]
                if not isinstance(definitions, dict) or set(definitions) != set(tables):
                    raise CatalogError("Vehicle table names and contents differ")
                clean["tables"] = {}
                for key in sorted(definitions):
                    value = validate_definition_node(definitions[key])
                    if value["type"] != "table":
                        raise CatalogError("Vehicle requirement root is not a table")
                    clean["tables"][key] = value
            cleaned.append(clean)
            count += 1
        normalized.append({"id": record["id"], "mechanic_type": record["mechanic_type"],
                           "engine_repair_level": record["engine_repair_level"], "parts": cleaned})
    canonical = {"schema_version": version, "npc_compatibility": "UNKNOWN", "records": normalized}
    actual = hashlib.sha256(json.dumps(canonical, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    if actual != digest:
        raise CatalogError("Vehicle details hash mismatch")
    return {"vehicles": seen, "parts": count, "unresolved_items": unresolved}


def validate_survival_details(proof, items, required=False):
    detail, digest = proof.get('survival_details'), proof.get('survival_details_sha256')
    if detail is None and digest is None and not required:
        return {'forage': set(), 'traps': 0, 'animals': 0, 'unresolved_items': set()}
    if (not isinstance(detail, dict) or set(detail) != {'schema_version', 'npc_compatibility', 'traps', 'animals', 'forage'}
            or type(detail['schema_version']) is not int or detail['schema_version'] != 1
            or detail['npc_compatibility'] != 'UNKNOWN'):
        raise CatalogError('Invalid survival schema or compatibility claim')
    traps = validate_definition_node(detail['traps'])
    animals = validate_definition_node(detail['animals'])
    if traps['type'] != 'table' or animals['type'] != 'table':
        raise CatalogError('Survival registries must be tables')
    records = detail['forage']
    if not isinstance(records, list) or len(records) > 10_000:
        raise CatalogError('Invalid forage count')
    seen, references, normalized = set(), set(), []
    for record in records:
        if not isinstance(record, dict) or set(record) != {'id', 'fields', 'unexported_fields'}:
            raise CatalogError('Malformed forage definition')
        identifier, fields, omitted = record['id'], record['fields'], record['unexported_fields']
        if not isinstance(identifier, str) or not identifier.strip() or identifier in seen:
            raise CatalogError('Invalid/duplicate forage ID')
        seen.add(identifier)
        references.add(identifier)
        if not isinstance(fields, dict) or len(fields) > 1000 or any(not isinstance(k, str) for k in fields):
            raise CatalogError('Invalid forage fields')
        if (not isinstance(omitted, list) or len(omitted) > 1000
                or any(not isinstance(k, str) for k in omitted) or len(omitted) != len(set(omitted))
                or set(omitted) & set(fields)):
            raise CatalogError('Invalid forage omissions')
        clean = {k: validate_definition_node(v) for k, v in sorted(fields.items())}
        if clean.get('type') != {'type': 'string', 'scalar': identifier, 'entries': []}:
            raise CatalogError('Forage identifier/type mismatch')
        normalized.append({'id': identifier, 'fields': clean, 'unexported_fields': omitted})
    def fields(node):
        if node['type'] != 'table': raise CatalogError('Expected survival record table')
        return {e['key']: e['value'] for e in node['entries'] if e['key_type'] == 'string'}
    def item(node):
        if node['type'] != 'string' or not node['scalar'].strip():
            raise CatalogError('Invalid survival item reference')
        references.add(node['scalar'])
    for entry in traps['entries']:
        values = fields(entry['value'])
        if 'type' not in values: raise CatalogError('Trap type missing')
        item(values['type'])
        destroyed = values.get('destroyItem')
        if destroyed is not None:
            if destroyed['type'] == 'table':
                for value in destroyed['entries']: item(value['value'])
            else: item(destroyed)
    for entry in animals['entries']:
        values = fields(entry['value'])
        if 'item' in values: item(values['item'])
        for key in ('baits', 'traps'):
            if key not in values: continue
            for identifier in fields(values[key]): references.add(identifier)
    canonical = {'schema_version': 1, 'npc_compatibility': 'UNKNOWN',
                 'traps': traps, 'animals': animals, 'forage': normalized}
    actual = hashlib.sha256(json.dumps(canonical, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    if actual != digest: raise CatalogError('Survival details hash mismatch')
    item_ids = {r['full_type'] for r in items['records']}
    return {'forage': seen, 'traps': len(traps['entries']), 'animals': len(animals['entries']),
            'unresolved_items': references - item_ids}


def validate_fishing_details(proof, items, required=False):
    detail, digest = proof.get('fishing_details'), proof.get('fishing_details_sha256')
    empty = {'fish': 0, 'lures': set(), 'references': set(),
             'alias_resolutions': {}, 'unresolved_items': set()}
    if detail is None and digest is None and not required:
        return empty
    if (not isinstance(detail, dict) or set(detail) != {'schema_version', 'npc_compatibility', 'fields'}
            or type(detail['schema_version']) is not int or detail['schema_version'] != 1
            or detail['npc_compatibility'] != 'UNKNOWN'):
        raise CatalogError('Invalid fishing schema or compatibility claim')
    expected = {'lure', 'fishes', 'trashItems', 'line', 'hook', 'rods',
                'breakRodReplacement', 'fishNet', 'fishNetWithBait'}
    if not isinstance(detail['fields'], dict) or set(detail['fields']) != expected:
        raise CatalogError('Fishing fields missing or unexpected')
    fields = {key: validate_definition_node(detail['fields'][key]) for key in sorted(expected)}
    if any(node['type'] != 'table' for node in fields.values()):
        raise CatalogError('Fishing definition field is not a table')
    def mapping(node):
        result = {}
        for entry in node['entries']:
            if entry['key_type'] != 'string' or entry['key'] in result:
                raise CatalogError('Fishing map requires unique string keys')
            result[entry['key']] = entry['value']
        return result
    def sequence(node):
        indexed = {}
        for entry in node['entries']:
            if entry['key_type'] != 'number': raise CatalogError('Fishing list requires numeric keys')
            number = float(entry['key'])
            if number != int(number) or number < 1: raise CatalogError('Invalid fishing list index')
            indexed[int(number)] = entry['value']
        if set(indexed) != set(range(1, len(indexed) + 1)):
            raise CatalogError('Sparse fishing list')
        return [indexed[i] for i in range(1, len(indexed) + 1)]
    def item(value):
        if value['type'] != 'string' or not value['scalar'].strip():
            raise CatalogError('Invalid fishing item reference')
        references.add(value['scalar']); return value['scalar']
    references = set()
    lure_groups = mapping(fields['lure'])
    if 'All' not in lure_groups or lure_groups['All']['type'] != 'table':
        raise CatalogError('Fishing All lure index missing')
    indexed_lures = set(mapping(lure_groups['All']))
    category_lures = set()
    for category, node in lure_groups.items():
        if node['type'] != 'table': raise CatalogError('Fishing lure group is not a table')
        if category != 'All': category_lures.update(mapping(node))
    if not indexed_lures or indexed_lures != category_lures:
        raise CatalogError('Fishing lure index differs from categories')
    references.update(indexed_lures)
    fish_count = 0
    for node in sequence(fields['fishes']):
        config = mapping(node)
        item(config.get('itemType', {})); fish_count += 1
        lure = config.get('lure')
        if lure is None or lure['type'] != 'table': raise CatalogError('Fish lure table missing')
        references.update(mapping(lure))
    for name in ('trashItems', 'fishNet', 'fishNetWithBait'):
        for value in sequence(fields[name]): item(value)
    for name in ('line', 'hook', 'rods'):
        references.update(mapping(fields[name]))
    for source, replacement in mapping(fields['breakRodReplacement']).items():
        references.add(source); item(replacement)
    canonical = {'schema_version': 1, 'npc_compatibility': 'UNKNOWN', 'fields': fields}
    actual = hashlib.sha256(json.dumps(canonical, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    if actual != digest: raise CatalogError('Fishing details hash mismatch')
    item_ids = {r['full_type'] for r in items['records']}
    unresolved = references - item_ids
    # Fish:getFish() sends trash strings through instanceItem(), which calls
    # InventoryItemFactory.CreateItem(). In the installed runtime that factory
    # retries a missing *Empty identifier without its suffix. Keep this narrow
    # native rule explicit; it does not make other similarly named items aliases.
    native_aliases = {'Base.WaterBottleEmpty': 'Base.WaterBottle'}
    alias_resolutions = {}
    for raw, resolved in native_aliases.items():
        if raw in unresolved and resolved in item_ids:
            alias_resolutions[raw] = resolved
            unresolved.remove(raw)
    return {'fish': fish_count, 'lures': indexed_lures, 'references': references,
            'alias_resolutions': alias_resolutions, 'unresolved_items': unresolved}


def validate_moveable_details(proof, items, required=False):
    detail, digest = proof.get('moveable_details'), proof.get('moveable_details_sha256')
    empty = {'tools': 0, 'materials': 0, 'scrap': 0, 'repairs': 0,
             'references': set(), 'tags': set(), 'unresolved_items': set()}
    if detail is None and digest is None and not required:
        return empty
    if (not isinstance(detail, dict) or set(detail) != {'schema_version', 'npc_compatibility', 'fields'}
            or type(detail['schema_version']) is not int or detail['schema_version'] != 1
            or detail['npc_compatibility'] != 'UNKNOWN'):
        raise CatalogError('Invalid moveable schema or compatibility claim')
    expected = {'toolDefinitions', 'matsDefinitions', 'scrapDefinitions',
                'healthDefinitions', 'repairDefinitions', 'floorReplaceSprites'}
    if not isinstance(detail['fields'], dict) or set(detail['fields']) != expected:
        raise CatalogError('Moveable fields missing or unexpected')
    fields = {key: validate_definition_node(detail['fields'][key]) for key in sorted(expected)}
    if any(node['type'] != 'table' for node in fields.values()):
        raise CatalogError('Moveable definition field is not a table')

    def mapping(node, label):
        result = {}
        for entry in node['entries']:
            if entry['key_type'] != 'string' or entry['key'] in result:
                raise CatalogError(f'{label} requires unique string keys')
            result[entry['key']] = entry['value']
        return result

    def sequence(node, label):
        indexed = {}
        for entry in node['entries']:
            if entry['key_type'] != 'number': raise CatalogError(f'{label} requires numeric keys')
            number = float(entry['key'])
            if number != int(number) or number < 1: raise CatalogError(f'Invalid {label} index')
            indexed[int(number)] = entry['value']
        if set(indexed) != set(range(1, len(indexed) + 1)):
            raise CatalogError(f'Sparse {label}')
        return [indexed[i] for i in range(1, len(indexed) + 1)]

    references, tags = set(), set()
    def reference(node, label):
        if node['type'] != 'string' or not node['scalar'].strip():
            raise CatalogError(f'Invalid {label} reference')
        value = node['scalar']
        (tags if value.startswith('Tag.') else references).add(value)

    def references_in_sequence(config, field, label):
        node = config.get(field)
        if node is None: return
        if node['type'] != 'table': raise CatalogError(f'Invalid {label} list')
        for value in sequence(node, label): reference(value, label)

    tools = mapping(fields['toolDefinitions'], 'moveable tool map')
    for value in tools.values():
        config = mapping(value, 'moveable tool definition')
        references_in_sequence(config, 'items', 'moveable tool items')

    materials = mapping(fields['matsDefinitions'], 'moveable material map')
    for value in materials.values():
        for entry in sequence(value, 'moveable material records'):
            config = mapping(entry, 'moveable material record')
            if 'returnItem' not in config: raise CatalogError('Moveable material return item missing')
            reference(config['returnItem'], 'moveable material item')

    scrap = mapping(fields['scrapDefinitions'], 'moveable scrap map')
    for value in scrap.values():
        config = mapping(value, 'moveable scrap definition')
        for field in ('tools', 'tools2'):
            references_in_sequence(config, field, 'moveable scrap tools')
        for field in ('returnItems', 'returnItemsStatic'):
            node = config.get(field)
            if node is None: continue
            for entry in sequence(node, 'moveable scrap returns'):
                result = mapping(entry, 'moveable scrap return')
                if 'returnItem' not in result: raise CatalogError('Moveable scrap return item missing')
                reference(result['returnItem'], 'moveable scrap return item')
        if 'unusableItem' in config:
            reference(config['unusableItem'], 'moveable unusable item')

    repairs = mapping(fields['repairDefinitions'], 'moveable repair map')
    for value in repairs.values():
        config = mapping(value, 'moveable repair definition')
        for field in ('tools', 'tools2'):
            references_in_sequence(config, field, 'moveable repair tools')
        parts = config.get('parts')
        if parts is None or parts['type'] != 'table': raise CatalogError('Moveable repair parts missing')
        for entry in sequence(parts, 'moveable repair parts'):
            part = mapping(entry, 'moveable repair part')
            if 'itemType' not in part: raise CatalogError('Moveable repair item type missing')
            reference(part['itemType'], 'moveable repair item')

    # These are sprite names, not inventory IDs, but their list shape and the
    # material modifier map are still part of the effective hashed definition.
    sequence(fields['floorReplaceSprites'], 'moveable floor replacement sprites')
    mapping(fields['healthDefinitions'], 'moveable health map')

    canonical = {'schema_version': 1, 'npc_compatibility': 'UNKNOWN', 'fields': fields}
    actual = hashlib.sha256(json.dumps(canonical, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
    if actual != digest: raise CatalogError('Moveable details hash mismatch')
    item_ids = {r['full_type'] for r in items['records']}
    short_names = {}
    for item_id in item_ids:
        short_names.setdefault(item_id.rsplit('.', 1)[-1], []).append(item_id)
    alias_resolutions, unresolved = {}, set()
    for value in references:
        if value in item_ids:
            continue
        choices = sorted(short_names.get(value, ())) if '.' not in value else []
        if len(choices) == 1:
            alias_resolutions[value] = choices[0]
        else:
            unresolved.add(value)
    return {'tools': len(tools), 'materials': len(materials), 'scrap': len(scrap),
            'repairs': len(repairs), 'references': references, 'tags': tags,
            'alias_resolutions': alias_resolutions, 'unresolved_items': unresolved}


def validate_content_manifest(proof):
    if proof.get("enabled_mods_content_algorithm") != "selected-common-version-roots-v1":
        raise CatalogError("Unknown selected-content fingerprint algorithm")
    content = proof.get("enabled_mods_content")
    if not isinstance(content, list) or not content:
        raise CatalogError("Effective mod content manifest is missing")
    ids = []
    for entry in content:
        if (not isinstance(entry, dict) or set(entry) != {"mod_id", "roots", "sha256"}
                or not isinstance(entry["mod_id"], str) or not entry["mod_id"]
                or not HASH.fullmatch(str(entry["sha256"]))):
            raise CatalogError("Invalid effective mod content manifest entry")
        ids.append(entry["mod_id"])
        roots = entry["roots"]
        if not isinstance(roots, list) or len(roots) != 2:
            raise CatalogError("Expected common and selected version roots")
        for index, root in enumerate(roots):
            if not isinstance(root, dict) or set(root) != {"bytes", "file_count", "path", "sha256", "status"}:
                raise CatalogError("Invalid selected root record")
            path = root["path"]
            if (not isinstance(path, str) or not path or path in (".", "..")
                    or any(char in path for char in "/\\:") or any(ord(char) < 32 for char in path)):
                raise CatalogError("Root must name a direct selected subdirectory")
            if index == 0 and path != "common":
                raise CatalogError("Common root must precede the version root")
            if index == 1 and path == "common":
                raise CatalogError("Version root cannot repeat the common root")
            for field in ("bytes", "file_count"):
                if type(root[field]) is not int or root[field] < 0:
                    raise CatalogError("Invalid selected content count")
            if root["status"] == "ABSENT":
                if root["sha256"] is not None or root["bytes"] != 0 or root["file_count"] != 0:
                    raise CatalogError("Invalid absent selected root")
            elif root["status"] != "PRESENT" or not HASH.fullmatch(str(root["sha256"])):
                raise CatalogError("Invalid selected root hash/status")
        if sum(root["file_count"] for root in roots) == 0:
            raise CatalogError("Loaded mod has no selected content")
        if canonical_hash(roots) != entry["sha256"]:
            raise CatalogError("Selected roots do not match their mod digest")
    if ids != proof.get("enabled_mods") or len(set(ids)) != len(ids):
        raise CatalogError("Effective mod order does not match its content manifest")
    if canonical_hash(content) != proof.get("enabled_mods_fingerprint"):
        raise CatalogError("Effective mod content fingerprint mismatch")


def resolve_identifier(value, exact_ids, aliases):
    """Resolve only exact IDs or explicit catalog-backed aliases; never invent IDs."""
    if not isinstance(value, str) or not value:
        raise CatalogError("Identifier must be nonempty text")
    if value in exact_ids:
        return value
    choices = aliases.get(value.casefold(), [])
    if not isinstance(choices, list) or any(not isinstance(choice, str) for choice in choices):
        raise CatalogError("Alias entries must list exact IDs")
    if len(choices) != 1 or choices[0] not in exact_ids:
        raise CatalogError("Unknown, ambiguous, or stale alias")
    return choices[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, default=Path("reference"))
    parser.add_argument("--require-runtime", action="store_true")
    parser.add_argument("--require-supplemental", action="store_true")
    parser.add_argument("--require-fixing-details", action="store_true")
    parser.add_argument("--require-evolved-details", action="store_true")
    parser.add_argument("--require-crop-details", action="store_true")
    parser.add_argument("--require-vehicle-details", action="store_true")
    parser.add_argument("--require-vehicle-tables", action="store_true")
    parser.add_argument("--require-survival-details", action="store_true")
    parser.add_argument("--require-fishing-details", action="store_true")
    parser.add_argument("--require-moveable-details", action="store_true")
    args = parser.parse_args()
    try:
        items = read_catalog(args.reference / "pz-items.json")
        recipes = read_catalog(args.reference / "pz-recipes.json")
        proof = read_catalog(args.reference / "pz-runtime-fingerprint.json")
        payloads = {filename: (args.reference / filename).read_bytes() for filename in ("pz-items.json", "pz-recipes.json")}
        item_ids, recipe_ids = validate_export_set(items, recipes, proof, payloads, args.require_runtime)
        if args.require_supplemental:
            validate_supplemental_catalog(proof, required=True)
        if args.require_fixing_details:
            validate_fixing_details(proof, items, required=True)
        if args.require_evolved_details:
            validate_evolved_details(proof, items, required=True)
        if args.require_crop_details:
            crop_result = validate_crop_details(proof, items, required=True)
            print(f"Crop definitions: {len(crop_result['crops'])}; unresolved item references: {len(crop_result['unresolved_items'])}.")
        if args.require_vehicle_details or args.require_vehicle_tables:
            vehicle_result = validate_vehicle_details(proof, items, required=True,
                                                     require_tables=args.require_vehicle_tables)
            print(f"Vehicle definitions: {len(vehicle_result['vehicles'])}; parts: {vehicle_result['parts']}; unresolved item references: {len(vehicle_result['unresolved_items'])}.")
        if args.require_survival_details:
            result = validate_survival_details(proof, items, required=True)
            print(f"Survival definitions: {result['traps']} traps, {result['animals']} animals, {len(result['forage'])} forage; unresolved items: {len(result['unresolved_items'])}.")
        if args.require_fishing_details:
            result = validate_fishing_details(proof, items, required=True)
            aliases = ', '.join(f'{source}->{target}' for source, target in sorted(result['alias_resolutions'].items())) or 'none'
            print(f"Fishing definitions: {result['fish']} fish, {len(result['lures'])} lures; native aliases: {aliases}; unresolved raw items: {len(result['unresolved_items'])}.")
        if args.require_moveable_details:
            result = validate_moveable_details(proof, items, required=True)
            print(f"Moveable definitions: {result['tools']} tools, {result['materials']} materials, {result['scrap']} scrap, {result['repairs']} repairs; unresolved items: {len(result['unresolved_items'])}.")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Catalog validation failed: {error}\n")
    print(f"Structure validated: {len(item_ids)} item IDs; {len(recipe_ids)} recipe IDs.")
    print("This does not prove Lua bindings, IsoZombie compatibility, or multiplayer execution.")


if __name__ == "__main__":
    main()
