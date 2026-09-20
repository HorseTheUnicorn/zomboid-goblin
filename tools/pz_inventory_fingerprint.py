"""Read-only installed-content fingerprint; never claims loaded-registry proof.

Run on the target host with --game and --config. Prints a secret-free JSON
report to stdout; does not write files, launch a game, or evaluate mod code.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path


def filesystem_path(path: Path) -> Path:
    """Avoid silently omitted >260-character paths on Windows installations."""
    value = str(path.absolute())
    if os.name != "nt" or value.startswith("\\\\?\\"):
        return Path(value)
    if value.startswith("\\\\"):
        return Path("\\\\?\\UNC\\" + value[2:])
    return Path("\\\\?\\" + value)


def sha256(path: Path) -> str:
    path = filesystem_path(path)
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_fingerprint(root: Path) -> dict:
    root = filesystem_path(root)
    def redirected(path):
        return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())

    if redirected(root) or not root.is_dir():
        raise ValueError(f"Missing or symlinked content root: {root}")
    digest = hashlib.sha256()
    files = 0
    size = 0
    for path in sorted(root.rglob("*"), key=lambda p: p.relative_to(root).as_posix()):
        if redirected(path):
            raise ValueError(f"Symlink requires explicit provenance review: {path}")
        if not path.is_file():
            continue
        before = path.stat()
        file_hash = sha256(path)
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError(f"Content changed while hashing: {path}")
        record = [path.relative_to(root).as_posix(), after.st_size, file_hash]
        digest.update(json.dumps(record, ensure_ascii=True, separators=(",", ":")).encode())
        digest.update(b"\n")
        files += 1
        size += after.st_size
    if files == 0:
        raise ValueError(f"Required content root is empty: {root}")
    return {"sha256": digest.hexdigest(), "file_count": files, "bytes": size}


def selected_config(path: Path) -> dict:
    # Never serialize passwords, RCON secrets or the complete server INI.
    result = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        key, separator, value = line.partition("=")
        if separator and key in {"Mods", "WorkshopItems", "PauseEmpty"}:
            if key in result:
                raise ValueError(f"Duplicate relevant config key: {key}")
            result[key] = value.strip()
    if not {"Mods", "WorkshopItems"} <= result.keys():
        raise ValueError("Server configuration lacks explicit Mods/WorkshopItems")
    return result


def collect(game: Path, config: Path) -> dict:
    settings = selected_config(config)
    ids = [item for item in settings["WorkshopItems"].split(";") if item]
    if any(not item.isascii() or not item.isdigit() for item in ids):
        raise ValueError("Unexpected Workshop identifier")
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate configured Workshop identifier")
    workshop = game / "steamapps/workshop/content/108600"
    content = [{"workshop_id": item, **tree_fingerprint(workshop / item)} for item in ids]
    java = game / "java/projectzomboid.jar"
    if not java.is_file():
        java = game / "projectzomboid.jar"
    manifest = game / "steamapps/workshop/appworkshop_108600.acf"
    identity = {
        "game_jar_sha256": sha256(java),
        "vanilla_scripts": tree_fingerprint(game / "media/scripts"),
        "vanilla_lua": tree_fingerprint(game / "media/lua"),
        "configured_mod_ids": [mod for mod in settings["Mods"].split(";") if mod],
        "configured_workshop_content": content,
    }
    identity_hash = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {
        "schema_version": 1,
        "evidence": "STATIC_INSTALLED",
        "export_timestamp": datetime.now(timezone.utc).isoformat(),
        "installed_content_fingerprint": identity_hash,
        "fingerprint_algorithm": "sha256 of canonical sorted-key JSON identity; tree records are path,size,sha256 JSON lines",
        "identity": identity,
        "workshop_manifest_sha256": sha256(manifest) if manifest.is_file() else None,
        "pause_empty_configured": settings.get("PauseEmpty"),
        "loaded_registry_verified": False,
        "limitations": [
            "Configured mod order is not proof of effective loaded mod order or dependencies.",
            "Workshop content hashes include every file in configured items, including inactive versions/submods.",
            "Local mods outside Workshop require separate capture and runtime reconciliation.",
            "Per-file change detection is not an atomic whole-install snapshot; reconcile with runtime export.",
        ],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(collect(args.game, args.config), indent=2, ensure_ascii=True))
