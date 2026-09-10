# Deployment

`.03` is the dedicated Project Zomboid Build 42 server. `.76` runs the
Python/Qwen/Discord relay, memory, IPC, and read-only tracker. `.76` does not
need Steam or a PZ client.

## Server mod

Install `mod/Contents/mods/GoblinSurvivor` under the server's Build 42 mod
path. The package contains `42/` Lua code, the custom Bob AnimSets, and the
Mystery Rig FBX/clothing resources under `common/media`. No Workshop framework
dependency is required. Joining
players connect normally and receive the replicated body through the ordinary
multiplayer protocol.

The direct server package is conventionally:

```text
/home/zomboid/Zomboid/mods/GoblinSurvivor
```

The bridge root is:

```text
/home/zomboid/Zomboid/Lua/goblin-bridge
```

Run `ops/pz-bridge/provision_bridge.sh` on the server host to create the
bounded bridge channels and the default `config.ini`. The important settings
are `GoblinEnabled=true`, `GoblinNpcId=goblin.primary`,
`GoblinNpcOutfit=Survivor`, `GoblinNpcVisualAsset=Goblin_PZ_MysteryRig`,
`GoblinWeapon=Base.Machete`, and the follow/spawn
distances shown in `ops/server-options.example`. Set `GoblinEnabled=false`
for a deliberate maintenance pause.

Before a restart, take a bounded backup of the package, bridge configuration,
and save. Keep backups outside `Zomboid/mods`; sibling directories can be
discovered by the mod loader. Restart only the dedicated-server unit, inspect
the newest DebugLog, and confirm the bootstrap line reports
`adapter=iso_zombie friendly=true control_ready=true`.

## Agent

Start the Python service with
`python -m goblin_zomboid.daemon` (the example unit is under `systemd/`). The
service consumes Qwen/Discord events and publishes only typed high-level
commands. If the bridge marker is missing, the local server companion still
spawns and follows its persisted owner.

## Acceptance checks

- There is no Steam/PZ client on `.76` and no second/dev/roster NPC in the
  world.
- With an owner online, `runtime.state` reports `npc_id=goblin.primary`,
  `body_mode=npc`, `control_ready=true`, `npc_engine_ready=true`, and
  `engine=iso_zombie`.
- The body has Survivor visuals and transitions through `IDLE`, `PATHING`,
  `WALKING`, and `RUNNING` while `Bob_*` nodes are selected.
- A `FOLLOW` command stays on the owner ring; an authorized developer
  `MOVE_TO` exercises native `PathFindBehavior2`.
- A death or restart produces at most one replacement after the persisted
  cooldown; restart-safe generation reconciliation retires stale marked
  bodies, and ordinary zombies are never adopted.
- Every accepted IPC command receives a bounded response/ack and archive
  marker. Exact coordinates appear only in `runtime.exact_state`/tracker.
