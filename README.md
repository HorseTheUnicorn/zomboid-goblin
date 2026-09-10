# Zomboid Goblin

Goblin is one persistent, server-authoritative Project Zomboid Build 42
companion. The dedicated server owns a networked `IsoZombie`; the mod marks
that body with Goblin identity, applies a human Survivor outfit, and selects
the vanilla player `Bob_*` animation nodes through custom AnimSet conditions.
Movement is native `PathFindBehavior2`, with a deterministic task/physical
state controller and no coordinate interpolation or native fence-climb hacks.

The normal world contains exactly one Goblin (`goblin.primary`). There is no
external NPC framework dependency, `IsoSurvivor`, managed NPC roster, dev
survivor, or client-side gameplay process. The body is created with the Build 42
`VirtualZombieManager` path and is protected/friendly by the server-side
invariant loop. If the body dies, the persisted generation and respawn
cooldown prevent duplicates.

## Runtime layout

- `.03`: dedicated PZ server, existing save, and the `GoblinSurvivor` mod.
- `.76`: Qwen, Python agent/relay, memory, IPC bridge, and read-only tracker;
  it has no Steam or Project Zomboid client.
- `goblin.primary`: the sole stable companion identity. The first online
  player becomes the persisted owner; an offline owner is not silently
  replaced.
- `common/media/AnimSets`: custom `Bob_Idle`, `Bob_Walk`, `Bob_Run`, melee,
  face-target, hit-reaction, stagger, and get-up nodes selected only when
  `GoblinNPC=true` and the corresponding Goblin state variables are present.

The Python process still owns Qwen/Discord orchestration, durable memory, and
the file-based IPC protocol. It emits only typed high-level intents. Lua
validates the envelope again, resolves semantic targets on the server, and
hands tasks to the deterministic Goblin brain. Exact Goblin coordinates are
published only on the tracker stream, never to Qwen.

## Character asset

The supplied Mystery Rig character handoff is preserved in
[art/goblin](art/goblin/README.md), including the Blender scene, FBX export,
build report, and source textures. The report validates the `Bip01` skeleton,
weights, scale, and the native `Bob_Idle`/`Bob_Walk`/`Bob_Run` animation gate.
The FBX is also packaged under
`common/media/models_X/Goblin_PZ_MysteryRig.fbx`, with adjacent `.fbm`
textures and a `Goblin_MysteryBody` `base:fullsuit` clothing definition. On
spawn/restore the server adds that real item to the IsoZombie inventory and
wears it through the normal replicated clothing path; the native Bob_* AnimSet
still owns animation selection.

## Configuration

The bridge provisioner writes `<cachedir>/Lua/goblin-bridge/config.ini` from
`ops/server-options.example`. The important defaults are:

```ini
GoblinEnabled=true
GoblinNpcId=goblin.primary
GoblinNpcOutfit=Survivor
GoblinNpcVisualAsset=Goblin_PZ_MysteryRig
GoblinWeapon=Base.Machete
GoblinNpcProtected=true
GoblinFollowDistance=3
GoblinFollowWalkDistance=4
GoblinFollowRunDistance=9
GoblinSpawnOffset=4
```

Keep `GoblinEnabled=true` for the ordinary one-Goblin test path. The optional
Qwen/Discord bridge can be absent; in-game developer commands and the default
FOLLOW behavior still run locally.

## Development

```text
python -m compileall -q goblin_zomboid tests
python -m unittest discover -s tests -v
```

The Python service is started with `python -m goblin_zomboid.daemon` through
the example unit in `systemd/goblin-zomboid-agent.service.example`. It exposes
loopback admin status on port `8781` and the read-only tracker API on `8782`.

See [docs/NPC_ARCHITECTURE.md](docs/NPC_ARCHITECTURE.md),
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), and
[docs/IPC_PROTOCOL.md](docs/IPC_PROTOCOL.md) for the current runtime and
operator workflow.
