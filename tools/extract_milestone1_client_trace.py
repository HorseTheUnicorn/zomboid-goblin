"""Extract an opt-in owning-client Goblin trace without claiming acceptance."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import tempfile

from tools.capture_milestone1_trace import installed_fingerprint, source_fingerprint


TRACE = re.compile(
    r"\bM1_CLIENT_TRACE t=(\d+) client=([\w-]+) id=([\w.-]+) "
    r"online=(\d+) remote=(true|false|nil) "
    r"x=(-?\d+(?:\.\d+)?) y=(-?\d+(?:\.\d+)?) z=(-?\d+(?:\.\d+)?) "
    r"px=(-?\d+(?:\.\d+)?) py=(-?\d+(?:\.\d+)?) pz=(-?\d+(?:\.\d+)?)"
    r"(?: prun=(true|false|nil) psprint=(true|false|nil))?"
    r"(?: outfit=(?:-?\d+|nil) roster_outfit=(?:-?\d+|nil))?\.?\s*$"
)


def parse_lines(lines, client, npc_id, online_id=None):
    samples = []
    for line in lines:
        if "M1_CLIENT_TRACE t=" not in line:
            continue
        match = TRACE.search(line)
        if not match:
            raise ValueError("malformed client trace line")
        stamp, name, identity, online, remote, *remaining = match.groups()
        coords, running, sprinting = remaining[:6], remaining[6], remaining[7]
        if name != client or identity != npc_id or (online_id is not None
                and int(online) != online_id):
            continue
        values = [float(value) for value in coords]
        if not all(math.isfinite(value) for value in values):
            raise ValueError("nonfinite client trace position")
        item = {
            "timestamp_ms": int(stamp), "client": name, "entity_id": identity,
            "online_id": int(online), "remote": remote == "true" if remote != "nil" else None,
            "actor": dict(zip(("x", "y", "z"), values[:3])),
            "player": dict(zip(("x", "y", "z"), values[3:])),
            "player_running": running == "true" if running is not None and running != "nil" else None,
            "player_sprinting": sprinting == "true" if sprinting is not None and sprinting != "nil" else None,
        }
        if samples and item["timestamp_ms"] <= samples[-1]["timestamp_ms"]:
            raise ValueError("nonmonotonic client trace timestamp")
        samples.append(item)
    if len(samples) < 2:
        raise ValueError("fewer than two matching client trace samples")
    return samples


def summary(samples):
    def point(item, key):
        return tuple(item[key][axis] for axis in ("x", "y", "z"))

    steps = [math.dist(point(a, "actor"), point(b, "actor"))
             for a, b in zip(samples, samples[1:])]
    player_steps = [math.dist(point(a, "player"), point(b, "player"))
                    for a, b in zip(samples, samples[1:])]
    intervals = [b["timestamp_ms"] - a["timestamp_ms"]
                 for a, b in zip(samples, samples[1:])]
    return {
        "sample_count": len(samples),
        "start_ms": samples[0]["timestamp_ms"],
        "end_ms": samples[-1]["timestamp_ms"],
        "actor_delta_tiles": math.dist(point(samples[0], "actor"), point(samples[-1], "actor")),
        "player_delta_tiles": math.dist(point(samples[0], "player"), point(samples[-1], "player")),
        "max_actor_step_tiles": max(steps),
        "max_interval_ms": max(intervals),
        "moving_actor_steps": sum(step > 0.01 for step in steps),
        "running_state_samples": sum(sample["player_running"] is not None
                                     or sample["player_sprinting"] is not None
                                     for sample in samples),
        "running_player_distance_tiles": sum(
            step for step, sample in zip(player_steps, samples[1:])
            if sample["player_running"] is True or sample["player_sprinting"] is True),
        "online_ids": sorted({sample["online_id"] for sample in samples}),
        "remote_values": sorted({str(sample["remote"]) for sample in samples}),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--client", required=True)
    parser.add_argument("--npc-id", required=True)
    parser.add_argument("--online-id", type=int,
                        help="Keep one native actor incarnation; exclude unload/rejoin gaps")
    parser.add_argument("--installed-mod", action="append", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("output exists; preserve the prior evidence")
    before = source_fingerprint()
    mod_roots = [path.resolve() for path in args.installed_mod]
    if len(set(mod_roots)) != len(mod_roots):
        parser.error("installed mod roots must be distinct")
    if any(installed_fingerprint(root) != before for root in mod_roots):
        parser.error("installed runtime differs from current worktree")
    raw = args.source.read_bytes()
    samples = parse_lines(raw.decode("utf-8", errors="replace").splitlines(),
                          args.client, args.npc_id, args.online_id)
    after = source_fingerprint()
    if after != before or any(installed_fingerprint(root) != after for root in mod_roots):
        parser.error("runtime changed during trace extraction")
    record = {
        "schema_version": 1,
        "kind": "raw_owning_client_milestone_1_trace_not_acceptance",
        "source_log_sha256": hashlib.sha256(raw).hexdigest(),
        "source_sha256": before[0],
        "server_jar_sha256": before[1],
        "installed_mod_roots": [str(root) for root in mod_roots],
        "summary": summary(samples),
        "samples": samples,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".m1-client-", suffix=".tmp",
                                      dir=args.output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream, indent=2)
            stream.write("\n")
        os.link(temporary, args.output)
    finally:
        Path(temporary).unlink(missing_ok=True)
    print(json.dumps(record["summary"], indent=2))
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
