"""Capture raw, source-bound local multiplayer telemetry for Milestone 1.

This does not move players, issue commands, or certify an acceptance gate.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time

from tools.check_milestone1_acceptance import CURRENT_SOURCES


ROOT = Path(__file__).resolve().parents[1]
MOD_PREFIX = Path("mod/Contents/mods/GoblinSurvivor")
SERVER_JAR = Path("42/goblin-server.jar")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_fingerprint():
    hashes = {name: sha256(ROOT / relative)
              for name, relative in CURRENT_SOURCES.items()}
    return hashes, sha256(ROOT / MOD_PREFIX / SERVER_JAR)


def installed_fingerprint(mod_root):
    hashes = {name: sha256(mod_root / Path(relative).relative_to(MOD_PREFIX))
              for name, relative in CURRENT_SOURCES.items()}
    return hashes, sha256(mod_root / SERVER_JAR)


def verify_installed(mod_roots, source):
    for mod_root in mod_roots:
        if installed_fingerprint(mod_root) != source:
            raise ValueError(f"installed runtime differs from worktree: {mod_root}")


def snapshot(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    stamp = data.get("timestamp_ms")
    entities = data.get("entities")
    if not isinstance(stamp, (int, float)) or not isinstance(entities, list):
        raise ValueError("exact-state telemetry has no timestamp or entity list")
    result = []
    for entity in entities:
        if not isinstance(entity, dict) or entity.get("kind") not in ("player", "goblin"):
            continue
        result.append({key: entity[key] for key in (
            "entity_id", "kind", "online_id", "x", "y", "z", "native_owner_player", "simulation_owner"
        ) if key in entity})
    return {"timestamp_ms": stamp, "entities": result}


def capture(source, duration, interval):
    started = time.monotonic()
    last_stamp = None
    samples = []
    read_errors = 0
    while time.monotonic() - started < duration:
        try:
            item = snapshot(source)
            if item["timestamp_ms"] != last_stamp:
                item["observed_utc"] = datetime.now(timezone.utc).isoformat()
                samples.append(item)
                last_stamp = item["timestamp_ms"]
        except (OSError, json.JSONDecodeError, ValueError):
            read_errors += 1
        time.sleep(interval)
    return samples, read_errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--installed-mod", type=Path, action="append", required=True,
                        help="Repeat for the server and each ordinary client's loaded GoblinSurvivor mod root")
    args = parser.parse_args()
    if not 5 <= args.duration <= 300 or not 0.2 <= args.interval <= 2:
        parser.error("duration must be 5–300 seconds and interval 0.2–2 seconds")
    if args.output.exists():
        parser.error("output already exists; preserve the prior evidence")
    mod_roots = [path.resolve() for path in args.installed_mod]
    if len(set(mod_roots)) != len(mod_roots):
        parser.error("installed mod roots must be distinct")
    try:
        before = source_fingerprint()
        verify_installed(mod_roots, before)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    samples, read_errors = capture(args.source, args.duration, args.interval)
    if len(samples) < 2:
        parser.error("fewer than two fresh telemetry samples; no evidence written")
    try:
        after = source_fingerprint()
        verify_installed(mod_roots, after)
        if after != before:
            raise ValueError("worktree source changed during the capture")
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    record = {
        "schema_version": 1,
        "kind": "raw_milestone_1_trace_not_acceptance",
        "scenario": args.scenario,
        "source_sha256": before[0],
        "server_jar_sha256": before[1],
        "installed_mod_roots": [str(path) for path in mod_roots],
        "installed_fingerprint_matched_before_and_after": True,
        "capture_duration_seconds": args.duration,
        "read_errors": read_errors,
        "samples": samples,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".m1-trace-", suffix=".tmp", dir=args.output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream, indent=2)
            stream.write("\n")
        os.link(temporary, args.output)  # fail rather than replace another capture
    finally:
        Path(temporary).unlink(missing_ok=True)
    print(f"Captured {len(samples)} fresh snapshots; read errors={read_errors}; output={args.output}")


if __name__ == "__main__":
    main()
