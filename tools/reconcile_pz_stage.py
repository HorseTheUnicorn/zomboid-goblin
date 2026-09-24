"""Independently check runtime-selected content against the captured server copy.

Read-only source inspection; an optional output is a generated evidence report.
Only the explicitly supplied candidate Goblin helper is allowed to differ.
No Steam access, game launch, or production writes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from itertools import chain
from pathlib import Path

try:
    from tools.check_pz_catalog import read_catalog, validate_content_manifest, canonical_hash
    from tools.pz_inventory_fingerprint import filesystem_path, sha256
except ModuleNotFoundError:
    from check_pz_catalog import read_catalog, validate_content_manifest, canonical_hash
    from pz_inventory_fingerprint import filesystem_path, sha256


def selected_files(root: Path, optional=False):
    root = filesystem_path(root)
    if not root.exists():
        if optional:
            return None
        raise ValueError(f"Missing selected root: {root}")
    if not root.is_dir():
        raise ValueError("Selected root is not a directory")
    result = {}
    for index, path in enumerate(chain((root,), root.rglob("*"))):
        if index > 200_000:
            raise ValueError("Content tree exceeds reconciliation entry bound")
        if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
            raise ValueError("Redirected content cannot be reconciled implicitly")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError("Unsupported content entry")
        before = path.stat()
        digest = sha256(path)
        after = path.stat()
        if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
            raise ValueError("Content changed during reconciliation")
        result[path.relative_to(root).as_posix()] = (after.st_size, digest)
    return result


def root_record(path, records):
    if records is None:
        return {"bytes": 0, "file_count": 0, "path": path, "sha256": None, "status": "ABSENT"}
    digest = hashlib.sha256()
    # Match Java String ordering, including non-BMP filenames.
    for name in sorted(records, key=lambda value: value.encode("utf-16-be")):
        size, file_hash = records[name]
        digest.update(json.dumps([name, size, file_hash], ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        digest.update(b"\n")
    return {"bytes": sum(value[0] for value in records.values()), "file_count": len(records),
            "path": path, "sha256": digest.hexdigest(), "status": "PRESENT"}


def mod_id(directory, version):
    info = directory / version / "mod.info"
    if not info.is_file():
        info = directory / "common" / "mod.info"
    if not info.is_file():
        return None
    ids = [line.partition("=")[2].strip() for line in info.read_text(encoding="utf-8-sig").splitlines()
           if line.strip().startswith("id=")]
    if len(ids) != 1 or not ids[0]:
        raise ValueError(f"Ambiguous mod.info identity: {info}")
    return ids[0]


def locate(directories, identifier, version):
    matches = [directory for directory in directories if mod_id(directory, version) == identifier]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one selected folder for {identifier}: found {len(matches)}")
    return matches[0]


def reconcile(proof, snapshot, runtime_mods, candidate_helper, workshop_items):
    validate_content_manifest(proof)
    snapshot = filesystem_path(snapshot)
    runtime_mods = filesystem_path(runtime_mods)
    candidate_helper = filesystem_path(candidate_helper)
    workshop_root = snapshot / "steamapps/workshop/content/108600"
    if (not workshop_items or len(workshop_items) != len(set(workshop_items))
            or any(not item.isdecimal() for item in workshop_items)):
        raise ValueError("Expected unique numeric WorkshopItems IDs from the target server configuration")
    captured_dirs = []
    for item in workshop_items:
        item_root = workshop_root / item
        if not item_root.is_dir():
            raise ValueError(f"Configured Workshop item is missing from the snapshot: {item}")
        captured_dirs.extend((item_root / "mods").glob("*"))
    runtime_dirs = list(runtime_mods.iterdir())
    captured_dirs = [path for path in captured_dirs if path.is_dir()]
    runtime_dirs = [path for path in runtime_dirs if path.is_dir()]
    candidate_hash = sha256(candidate_helper)
    outcomes = []
    allowed_differences = []
    for entry in proof["enabled_mods_content"]:
        identifier = entry["mod_id"]
        version = entry["roots"][1]["path"]
        source = locate(captured_dirs, identifier, version)
        runtime = locate(runtime_dirs, identifier, version)
        source_roots = []
        for index, expected in enumerate(entry["roots"]):
            name = expected["path"]
            source_files = selected_files(source / name, optional=True)
            runtime_files = selected_files(runtime / name, optional=True)
            actual = root_record(name, runtime_files)
            if actual != expected:
                raise ValueError(f"Staged content no longer matches exported digest: {identifier}/{name}")
            source_roots.append(root_record(name, source_files))
            if (source_files is None) != (runtime_files is None):
                raise ValueError("Selected root presence differs from captured server")
            for relative in set(source_files or {}) | set(runtime_files or {}):
                before = (source_files or {}).get(relative)
                after = (runtime_files or {}).get(relative)
                if before == after:
                    continue
                # No added/deleted files and no implicit broad overlay exceptions.
                allowed = (identifier == "GoblinSurvivor" and index == 1
                           and relative == "goblin-server.jar" and before is not None and after is not None
                           and (runtime / name / relative).resolve() == candidate_helper.resolve()
                           and after[1] == candidate_hash)
                if not allowed:
                    raise ValueError(f"Unapproved snapshot difference: {identifier}/{name}/{relative}")
                allowed_differences.append({"mod_id": identifier, "path": name + "/" + relative,
                                            "captured_sha256": before[1], "candidate_sha256": after[1]})
        outcomes.append({"mod_id": identifier, "sha256": canonical_hash(source_roots), "roots": source_roots})
    vanilla = []
    game = runtime_mods.parent.parent / "game"
    for kind in ("scripts", "lua"):
        captured = selected_files(snapshot / "media" / kind)
        staged = selected_files(game / "media" / kind)
        if captured != staged:
            raise ValueError(f"Vanilla {kind} differs from captured server")
        vanilla.append(root_record("media/" + kind, staged))
    return {"schema_version": 1, "kind": "pz-stage-reconciliation",
            "export_timestamp": proof["export_timestamp"], "game_build": proof["game_build"],
            "runtime_enabled_mods_fingerprint": proof["enabled_mods_fingerprint"],
            "captured_selected_mods_fingerprint": canonical_hash(outcomes),
            "captured_selected_mods": outcomes, "vanilla_sources": vanilla,
            "allowed_candidate_differences": allowed_differences,
            "result": "MATCH_EXCEPT_EXPLICIT_CANDIDATE_HELPER",
            "limitations": ["Not a registry export executed on production.",
                            "No physical ability or multiplayer acceptance is implied.",
                            "Per-file stable reads, not an atomic whole-install snapshot."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fingerprint", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--runtime-mods", type=Path, required=True)
    parser.add_argument("--candidate-helper", type=Path, required=True)
    parser.add_argument("--workshop-items", required=True,
                        help="Semicolon-separated WorkshopItems from the target server configuration")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = reconcile(read_catalog(args.fingerprint), args.snapshot, args.runtime_mods,
                       args.candidate_helper, args.workshop_items.split(";"))
    if args.output:
        if args.output.exists():
            parser.error("Output already exists; preserve prior evidence or explicitly choose another file")
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Verified {len(report['captured_selected_mods'])} selected mods and both vanilla source trees; "
          f"{len(report['allowed_candidate_differences'])} explicit candidate helper difference(s).")


if __name__ == "__main__":
    main()
