# Zomboid Goblin

Goblin is a persistent, server-side Project Zomboid NPC. The dedicated Build
42 server owns a friendly Bandits2 body running Bandits2's `Companion`
behavior; GoblinSurvivor adds Goblin identity, safety, chat, high-level
commands, and persistence around that body. The Python service on `.76`
supplies bounded decisions and a read-only tracker. No Steam/PZ client is
installed or required on `.76`.

## Runtime layout

- `.03` (`192.168.0.3`): dedicated PZ server, existing save, Bandits2
  Workshop item `3268487204`, and the server-side GoblinSurvivor package.
- `.76` (`192.168.0.76`): local Qwen, Python agent/relay, memory, and tracker
  website/API. It has no Goblin gameplay client. The website is served by the
  same read-only tracker process and renders the current B42 map tiles copied
  from the server's installed map cache.
- `goblin.primary`: stable NPC identity. Death or unload is handled by the
  server-side registry and recovery loop.

The model sees `brain_view` only: named targets, coarse threat/distance
signals, and bounded events. Exact coordinates are stored separately in the
tracker telemetry path for the map and never enter Qwen context.

The GoblinSurvivor package includes the small client relay needed for
multiplayer conversation, while Bandits2 supplies the networked NPC body and
behavior. Joining clients therefore need the same Workshop dependencies that
the server advertises; Steam can download them as part of the server's
`WorkshopItems=` loadout. The relay forwards only a local player's chat when
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
semantic targets locally before calling the Bandits2-backed friendly NPC
adapter.
Unsupported engine capabilities fail closed.

See [docs/NPC_ARCHITECTURE.md](docs/NPC_ARCHITECTURE.md),
[docs/BANDITS_API_NOTES.md](docs/BANDITS_API_NOTES.md), and
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the current design and live
operator workflow.
