"""Check the recorded Milestone 1 live gates without reusing stale source proof."""

import hashlib
import math
from pathlib import Path
import re

from tools.check_pz_catalog import CatalogError, read_catalog


HISTORICAL_SOURCES = {
    name: f"mod/Contents/mods/GoblinSurvivor/42/media/lua/{folder}/GoblinSurvivor/{name}"
    for name, folder in (
        ("GoblinWorld.lua", "server"),
        ("GoblinAccess.lua", "server"),
        ("GoblinBody.lua", "server"),
        ("GoblinClient.lua", "client"),
        ("GoblinLocomotion.lua", "shared"),
        ("GoblinSpawner.lua", "server"),
    )
}
CURRENT_SOURCES = {
    **HISTORICAL_SOURCES,
    "GoblinGuard.lua":
        "mod/Contents/mods/GoblinSurvivor/42/media/lua/shared/GoblinSurvivor/GoblinGuard.lua",
    "turnalerted/goblinHumanFallback.xml":
        "mod/Contents/mods/GoblinSurvivor/common/media/AnimSets/zombie/turnalerted/goblinHumanFallback.xml",
    "GoblinClientTrace.lua":
        "mod/Contents/mods/GoblinSurvivor/42/media/lua/client/GoblinSurvivor/GoblinClientTrace.lua",
    **{
        name: f"mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/{name}"
        for name in (
            "GoblinAccessPolicy.lua", "GoblinAutonomy.lua", "GoblinBrain.lua",
            "GoblinGainAccess.lua", "GoblinMovement.lua", "GoblinTelemetry.lua",
            "GoblinTransport.lua", "GoblinWork.lua",
        )
    },
}
SERVER_JAR = "mod/Contents/mods/GoblinSurvivor/42/goblin-server.jar"
REQUIREMENTS = {
    "stable follow slots", "native follow investigation",
    "expanded work approach search", "staged stuck recovery",
    "navigation telemetry", "temporary route blacklist",
}
LIVE_GATES = {
    "closed_door_follow", "durable_radius_two_staging",
    "open_terrain_running_follow", "native_no_progress_recovery",
    "native_simulation_ownership_handoff", "furniture_detour",
    "stair_follow", "running_owner_building_follow", "managed_door_access",
}


def _point(sample, key, label):
    value = sample.get(key) if isinstance(sample, dict) else None
    require(isinstance(value, dict), f"{label} position is missing")
    coords = tuple(value.get(axis) for axis in ("x", "y", "z"))
    require(all(isinstance(number, (int, float)) and not isinstance(number, bool)
                and math.isfinite(number) for number in coords),
            f"{label} position is invalid")
    return coords


def _validate_native_run_trace(samples, label, expected_client):
    require(isinstance(samples, list) and len(samples) >= 4,
            f"{label} requires a continuous native running trace")
    require(isinstance(expected_client, str) and expected_client,
            f"{label} owner username is missing")
    previous = None
    first = None
    running_distance = 0.0
    actor_distance = 0.0
    online_id = None
    entity_id = None
    for sample in samples:
        require(isinstance(sample, dict) and sample.get("client") == expected_client
                and sample.get("remote") is False,
                f"{label} requires owning-client actor observations")
        current_id = sample.get("online_id")
        require(isinstance(current_id, int) and not isinstance(current_id, bool)
                and current_id >= 0,
                f"{label} actor online ID is invalid")
        if online_id is None:
            online_id = current_id
        require(current_id == online_id, f"{label} actor changed during measurement")
        current_entity = sample.get("entity_id")
        require(isinstance(current_entity, str) and current_entity,
                f"{label} actor identity is missing")
        if entity_id is None:
            entity_id = current_entity
        require(current_entity == entity_id,
                f"{label} actor changed during measurement")
        stamp = sample.get("timestamp_ms")
        require(isinstance(stamp, (int, float)) and not isinstance(stamp, bool)
                and math.isfinite(stamp), f"{label} timestamp is invalid")
        player = _point(sample, "player", label)
        actor = _point(sample, "actor", label)
        running = sample.get("player_running") is True or sample.get("player_sprinting") is True
        require(isinstance(sample.get("player_running"), bool)
                and isinstance(sample.get("player_sprinting"), bool),
                f"{label} native run state is missing")
        if first is None:
            first = (player, actor)
        if previous is not None:
            elapsed = stamp - previous[0]
            player_step = math.dist(player, previous[1])
            actor_step = math.dist(actor, previous[2])
            require(0 < elapsed <= 1000 and player_step <= 5 and actor_step <= 5,
                    f"{label} has a gap or teleport-sized step")
            if running and previous[3]:
                running_distance += player_step
            actor_distance += actor_step
        previous = (stamp, player, actor, running)
    require(running_distance > 10 and math.dist(first[0], previous[1]) > 10
            and actor_distance > 0.1 and math.dist(previous[1], previous[2]) <= 5,
            f"{label} has no sustained running-owner follow movement")
    return running_distance


def require(condition, message):
    if not condition:
        raise CatalogError(message)


def _validate_record_structure(data, schema_version, sources):
    require(data.get("schema_version") == schema_version
            and data.get("production_modified") is False
            and data.get("published") is False, "Milestone 1 release boundary is invalid")
    server = data.get("server")
    clients = data.get("clients")
    require(isinstance(server, dict) and server.get("steam") is False
            and server.get("storm_server_side") is True
            and isinstance(clients, list) and len(clients) >= 2,
            "Milestone 1 multiplayer topology is incomplete")
    first_two = clients[:2]
    require(all(client.get("ordinary_executable") is True and client.get("storm") is False
                and client.get("goblin_id") for client in first_two)
            and len({client["goblin_id"] for client in first_two}) == 2,
            "Milestone 1 ordinary-client companion evidence is incomplete")
    hashes = data.get("source_sha256")
    require(isinstance(hashes, dict) and set(hashes) == set(sources)
            and all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value)
                    for value in hashes.values()), "Milestone 1 source manifest is incomplete")
    if schema_version == 2:
        require(isinstance(data.get("server_jar_sha256"), str)
                and re.fullmatch(r"[0-9a-f]{64}", data["server_jar_sha256"]),
                "Current-source Milestone 1 server JAR hash is missing")
    milestone = data.get("milestone_1")
    require(isinstance(milestone, dict) and milestone.get("result") == "pass"
            and REQUIREMENTS <= set(milestone.get("requirements", [])),
            "Milestone 1 requirement claim is incomplete")
    for gate in LIVE_GATES:
        value = data.get(gate)
        require(isinstance(value, dict) and value.get("result") == "pass",
                f"Milestone 1 live gate is incomplete: {gate}")

    door = data["closed_door_follow"]
    require(door.get("initially_closed") is True
            and door.get("opened_by_goblin_access") is True and door.get("crossed") is True,
            "Closed-door crossing evidence is incomplete")
    stage = data["durable_radius_two_staging"]
    require(stage.get("target_initially_blocked") is True
            and stage.get("stage_reached") is True
            and stage.get("target_world_state_unchanged") is True,
            "Radius-two staging evidence is incomplete")
    run = data["open_terrain_running_follow"]
    require(run.get("owner_delta", 0) > 10 and run.get("goblin_delta", 0) > 0
            and run.get("teleport_after_measurement") is False,
            "Running-follow movement evidence is incomplete")
    if schema_version == 2:
        _validate_native_run_trace(run.get("owning_client_trace"),
                                   "Open-terrain running follow",
                                   run.get("owner_username"))
    recovery = data["native_no_progress_recovery"]
    require(recovery.get("native_repath_attempts") == 1
            and recovery.get("blacklist_expiry_ms", 0) >= 30000
            and recovery.get("resumed_delta", 0) > 0
            and recovery.get("teleport") is False,
            "Native recovery evidence is incomplete")
    handoff = data["native_simulation_ownership_handoff"]
    staging = handoff.get("staging") or {}
    observed = handoff.get("handoff_observation") or {}
    returned = handoff.get("return_observation") or {}
    require(staging.get("ownership_write") is False and staging.get("goblin_teleport") is False
            and observed.get("native_owner_player")
            and observed.get("native_owner_player") != handoff.get("initial_native_owner_player")
            and returned.get("native_owner_player") == handoff.get("initial_native_owner_player"),
            "Native ownership-handoff evidence is incomplete")
    if schema_version == 2:
        trace = handoff.get("actor_trace")
        require(isinstance(trace, list) and len(trace) >= 5
                and handoff.get("follow_rejoin_during_measurement") is False
                and handoff.get("goblin_position_write") is False,
                "Current-source handoff requires a continuous no-teleport actor trace")
        previous = None
        owners = []
        for sample in trace:
            actor = sample.get("actor") if isinstance(sample, dict) else None
            stamp = sample.get("timestamp_ms") if isinstance(sample, dict) else None
            owner = sample.get("native_owner_player") if isinstance(sample, dict) else None
            require(isinstance(actor, dict) and isinstance(stamp, (int, float))
                    and math.isfinite(stamp) and isinstance(owner, str) and owner,
                    "Current-source handoff trace sample is incomplete")
            coords = tuple(actor.get(axis) for axis in ("x", "y", "z"))
            require(all(isinstance(value, (int, float)) and math.isfinite(value)
                        for value in coords), "Current-source handoff actor position is invalid")
            if previous:
                elapsed = stamp - previous[0]
                step = math.dist(coords, previous[1])
                require(0 < elapsed <= 2000 and step <= 5,
                        "Current-source handoff has an unobserved or teleport-sized actor step")
            previous = (stamp, coords)
            owners.append(owner)
        require(owners[0] == handoff.get("initial_native_owner_player")
                and observed["native_owner_player"] in owners[1:-1]
                and owners[-1] == handoff.get("initial_native_owner_player"),
                "Current-source handoff trace does not show ownership return")
    furniture = data["furniture_detour"]
    require(furniture.get("actor_delta_tiles", 0) > 0
            and furniture.get("lateral_detour_tiles", 0) > 0
            and furniture.get("occupied_obstacle_square") is False
            and furniture.get("goblin_position_write") is False,
            "Furniture-detour evidence is incomplete")
    stairs = data["stair_follow"]
    require(len(stairs.get("ascent_observations", [])) >= 3
            and len(stairs.get("descent_owner_client_trace", [])) >= 3
            and stairs.get("goblin_position_write") is False,
            "Stair-follow evidence is incomplete")
    building = data["running_owner_building_follow"]
    require(building.get("owner_run", {}).get("delta_tiles", 0) > 10
            and len(building.get("actor_route", [])) >= 3
            and building.get("goblin_position_write") is False,
            "Building-follow evidence is incomplete")
    if schema_version == 2:
        _validate_native_run_trace(building.get("owning_client_trace"),
                                   "Building running follow",
                                   building.get("owner_username"))
    managed = data["managed_door_access"]
    ordinary = managed.get("ordinary_door") or {}
    require(ordinary.get("initial", {}).get("open") is False
            and ordinary.get("final", {}).get("open") is True
            and ordinary.get("exact_edge_crossed") is True
            and managed.get("goblin_position_write") is False,
            "Managed-door access evidence is incomplete")
    return len(sources), len(first_two), len(LIVE_GATES)


def validate_historical_record(data):
    """Validate the dated schema-1 record; it never certifies current source."""
    return _validate_record_structure(data, 1, HISTORICAL_SOURCES)


def validate(data, root):
    require(data.get("schema_version") == 2,
            "Milestone 1 legacy evidence cannot certify current source; recapture schema 2")
    result = _validate_record_structure(data, 2, CURRENT_SOURCES)
    root = Path(root).resolve()
    for name, relative in CURRENT_SOURCES.items():
        path = (root / relative).resolve()
        require(path.is_relative_to(root) and path.is_file(), f"Milestone 1 source missing: {name}")
        require(hashlib.sha256(path.read_bytes()).hexdigest() == data["source_sha256"][name],
                f"Milestone 1 source changed since acceptance: {name}")
    jar = (root / SERVER_JAR).resolve()
    require(jar.is_relative_to(root) and jar.is_file(), "Milestone 1 server JAR is missing")
    require(hashlib.sha256(jar.read_bytes()).hexdigest() == data["server_jar_sha256"],
            "Milestone 1 server JAR changed since acceptance")
    return result


def main():
    root = Path(__file__).resolve().parents[1]
    result = validate(read_catalog(root / "reference/pz-milestone1-live-acceptance.json"), root)
    print(f"Milestone 1 acceptance checked: {result[0]} sources, "
          f"{result[1]} ordinary clients, {result[2]} live gates.")


if __name__ == "__main__":
    main()
