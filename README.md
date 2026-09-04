# Zomboid Goblin

Goblin is a persistent, server-side Project Zomboid NPC. The dedicated Build
42 server owns an original, vanilla-API NPC body and its movement; the Python
service on `.76` supplies bounded high-level decisions and a read-only tracker.
No Steam/PZ client is installed or required on `.76`, and players do not need
to install a control client.

## Runtime layout

- `.03` (`192.168.0.3`): dedicated PZ server, existing save, and the
  server-side GoblinSurvivor package. No Bandits Workshop dependency is
  required.
- `.76` (`192.168.0.76`): local Qwen, Python agent/relay, memory, and tracker
  website/API. It has no Goblin gameplay client.
- `goblin.primary`: stable NPC identity. Death or unload is handled by the
  server-side registry and recovery loop.

The model sees `brain_view` only: named targets, coarse threat/distance
signals, and bounded events. Exact coordinates are stored separately in the
tracker telemetry path for the map and never enter Qwen context.

## Development

```text
python -m compileall -q goblin_zomboid tests
python -m unittest discover -s tests -v
```

The Python service is started with `python -m goblin_zomboid.daemon` through
the example unit in `systemd/goblin-zomboid-agent.service.example`. It exposes
loopback admin status on port `8781` and the read-only tracker API on `8782`.

## Tracker API

The tracker provides `GET /api/state`, `/api/events`, `/api/stream`,
`/api/history/goblin`, and `/api/health`. It intentionally has no gameplay
command, spawn, move, attack, or admin mutation endpoint.

## Safety boundary

Qwen emits one strict JSON intent. Python validates it, deterministic safety
and entity/job/squad gates inspect it, and `NpcBodyDriver` writes a typed
`command.npc_action` message. Lua validates the message again and resolves
semantic targets locally before calling the original vanilla NPC adapter.
Unsupported engine capabilities fail closed.

See [docs/NPC_ARCHITECTURE.md](docs/NPC_ARCHITECTURE.md), the historical
[docs/BANDITS_API_NOTES.md](docs/BANDITS_API_NOTES.md), and
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the current design and live
operator workflow.
