"""Validate the narrow, structured local acceptance claim for Milestone 2."""
import hashlib
from pathlib import Path

from tools.check_pz_catalog import CatalogError, read_catalog


SOURCES = {
    "GoblinCapabilities.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinCapabilities.lua",
    "GoblinJobs.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinJobs.lua",
    "GoblinFarming.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinFarming.lua",
    "GoblinCrafting.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinCrafting.lua",
    "GoblinVehicles.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinVehicles.lua",
    "GoblinCurtains.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinCurtains.lua",
    "GoblinBrain.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinBrain.lua",
    "GoblinBody.lua": "mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/GoblinBody.lua",
}


def validate(data, root):
    root = Path(root).resolve()
    if data.get("schema_version") != 1 or data.get("production_modified") is not False \
            or data.get("published") is not False:
        raise CatalogError("Milestone 2 acceptance has an invalid release boundary")
    milestone = data.get("milestone_2")
    required = {"capability registry", "structured job results",
                "adapt existing handlers without regression"}
    if not isinstance(milestone, dict) or milestone.get("result") != "pass" \
            or not required <= set(milestone.get("requirements", [])):
        raise CatalogError("Milestone 2 requirement claim is incomplete")
    server = data.get("server")
    clients = data.get("clients")
    if not isinstance(server, dict) or server.get("storm_server_side") is not True \
            or not isinstance(clients, list) or len(clients) < 2:
        raise CatalogError("Milestone 2 multiplayer topology is incomplete")
    first_two = clients[:2]
    if any(c.get("ordinary_executable") is not True or c.get("storm") is not False
           for c in first_two) or len({c.get("goblin_id") for c in first_two}) != 2:
        raise CatalogError("Milestone 2 ordinary-client companion evidence is incomplete")
    registry = data.get("registry")
    expected = {"CLOSE_CURTAINS", "CRAFT", "FARM", "REPAIR_VEHICLE"}
    if not isinstance(registry, dict) or registry.get("result") != "pass" \
            or registry.get("count") != 4 \
            or set(registry.get("registered_capabilities", [])) != expected:
        raise CatalogError("Milestone 2 registry evidence is incomplete")
    source_hashes = data.get("source_sha256")
    if not isinstance(source_hashes, dict) or set(source_hashes) != set(SOURCES):
        raise CatalogError("Milestone 2 source manifest is incomplete")
    for name, relative in SOURCES.items():
        path = (root / relative).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise CatalogError(f"Milestone 2 source missing: {name}")
        if hashlib.sha256(path.read_bytes()).hexdigest() != source_hashes[name]:
            raise CatalogError(f"Milestone 2 source changed since acceptance: {name}")
    craft = data.get("native_craft_through_registry")
    if not isinstance(craft, dict) or craft.get("result") != "pass" \
            or craft.get("capability") != "CRAFT" or craft.get("recipe") != "SawLogs" \
            or craft.get("requested_batches") != 1 \
            or craft.get("capability_errors") != 0 or craft.get("job_errors") != 0:
        raise CatalogError("Milestone 2 native craft evidence is incomplete")
    sequence = craft.get("result_sequence")
    if not isinstance(sequence, list) or len(sequence) != 2 \
            or sequence[0] != {"done": False, "success": True,
                               "code": "WORKING", "progress": 0} \
            or sequence[1].get("done") is not True \
            or sequence[1].get("success") is not True \
            or sequence[1].get("code") != "COMPLETE" \
            or sequence[1].get("progress") != 1:
        raise CatalogError("Milestone 2 structured result sequence is invalid")
    observed = craft.get("material_observation")
    if observed != {"Base.Log_before": 1, "Base.Log_after": 0,
                    "Base.Plank_before": 0, "Base.Plank_after": 3}:
        raise CatalogError("Milestone 2 material consumption/output evidence is invalid")
    return len(SOURCES), len(first_two), len(expected)


def main():
    root = Path(__file__).resolve().parents[1]
    result = validate(read_catalog(root / "reference/pz-milestone2-live-acceptance.json"), root)
    print(f"Milestone 2 acceptance checked: {result[0]} sources, "
          f"{result[1]} ordinary clients, {result[2]} registered capabilities.")


if __name__ == "__main__":
    main()
