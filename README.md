# Zomboid Goblin

Goblin is a persistent, server-side Project Zomboid NPC. GoblinSurvivor owns
the native Build 42 body creation and behavior layer: identity, friendly
filtering, navigation, bounded zombie combat, speech, persistence, and safe
recovery. The Python service on `.76` supplies bounded decisions and a
read-only tracker. No Steam/PZ client is installed or required on `.76`.

The mod uses the vanilla Build 42 `createZombie`/`SurvivorFactory` path when
available and falls back to the vanilla `addZombiesInOutfit` API only when the
descriptor path is unavailable. There is no external NPC framework or
Workshop body-engine dependency.

## Runtime layout

- `.03` (`192.168.0.3`): dedicated PZ server, existing save, and the
  server-side GoblinSurvivor package.
- `.76` (`192.168.0.76`): local Qwen, Python agent/relay, memory, and tracker
  website/API. It has no Goblin gameplay client. The website is served by the
  same read-only tracker process and renders the current B42 map tiles copied
  from the server's installed map cache.
- `goblin.primary`: stable NPC identity. Death or unload is handled by the
  server-side registry and recovery loop.
- `GoblinManagedNpcCount`: bounded optional roster size for our own friendly
  companions. The default live setting is `6`; set it to `0` for Goblin-only
  operation. Companions use the same native body engine but are owned, named,
  persisted, and squad-controlled by GoblinSurvivor.

The model sees `brain_view` only: named targets, coarse threat/distance
signals, and bounded events. Exact coordinates are stored separately in the
tracker telemetry path for the map and never enter Qwen context.

The GoblinSurvivor package includes the small client relay needed for
multiplayer conversation. Joining clients need GoblinSurvivor only; Steam can
download it as part of the server's `WorkshopItems=` loadout. The relay
forwards only a local player's chat when
the message mentions Goblin; the server verifies the sender, redacts
coordinate-like text, and sends the event to Python/Qwen. Authorized chat
requests also carry a one-use server-minted capability for squad/job/base
mutations; the capability is never included in the Qwen prompt and is
validated again by the server command loop. Goblin is still a server-side
NPC, not a Steam account or player client.

## Development

```text
python -m compileall -q goblin_zomboid tests
python -m unittest discover -s tests -v
```

The Python service is started with `python -m goblin_zomboid.daemon` through
the example unit in `systemd/goblin-zomboid-agent.service.example`. It exposes
loopback admin status on port `8781` and the read-only tracker API on `8782`.

## Tracker API

The tracker serves the read-only map website at `/` and provides
`GET /api/state`, `/api/events`, `/api/stream`, `/api/history/goblin`,
`/api/map/manifest`, and `/api/health`. B42 `biomemap` tiles are exposed only
through bounded `/map/biomemap_<x>_<y>.png` paths. It intentionally has no
gameplay command, spawn, move, attack, chat, or admin mutation endpoint.

## Safety boundary

Qwen emits one strict JSON intent. Python validates it, deterministic safety
and entity/job/squad gates inspect it, and `NpcBodyDriver` writes a typed
`command.npc_action` message. Lua validates the message again and resolves
semantic targets locally before calling the native GoblinSurvivor body
adapter.
Unsupported engine capabilities fail closed.

See [docs/NPC_ARCHITECTURE.md](docs/NPC_ARCHITECTURE.md),
[docs/NATIVE_NPC_ENGINE.md](docs/NATIVE_NPC_ENGINE.md), and
[docs/FRIENDLY_SURVIVOR_FRAMEWORK.md](docs/FRIENDLY_SURVIVOR_FRAMEWORK.md), and
[docs/LOCAL_TESTING.md](docs/LOCAL_TESTING.md) for the Windows development
loop, and [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the current live
operator workflow.
