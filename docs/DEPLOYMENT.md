# Deployment

## Hosts

`.03` is the dedicated PZ Build 42 server. `.76` runs the Python agent,
relay, local Qwen, and tracker. Use the Proxmox web console for `.03`; do not
depend on a direct SSH path to the container.

## Server-side mod

Install the self-contained `GoblinSurvivor` package under the server's Build
42 mod path and enable the server-side mod. Bandits2 was used as a behavior
reference during development and is not required by the server or joining
clients. The live server's target paths are:

```text
service: zomboid-servertest.service
server: /home/zomboid/pzserver
config: /home/zomboid/Zomboid/Server/servertest.ini
bridge: /home/zomboid/Zomboid/Lua/goblin-bridge
```

Before restarting, take a bounded backup of the server INI, GoblinSurvivor
package, and save. Restart only the dedicated-server unit and verify its
process and UDP query/game ports. Inspect the newest DebugLog for Lua errors.

## Agent

Provision the bridge root and environment on `.76`, then start
`goblin-zomboid-agent.service.example`. The service is disabled/paused by
default until an operator resumes it. Set `GOBLIN_TRACKER_PORT=8782` if the
default tracker port is unavailable. Keep Qwen loopback-only.

## Acceptance checks

- `.76` has no native PZ client, Steam GUI session, or gameplay SteamCMD tree.
- PZ writes `runtime.state` with `body_mode=npc`, `npc_id=goblin.primary`,
  `control_ready=true`, and `npc_engine_ready=true` after a player is online.
- `runtime.exact_state` is separate from `runtime.state`.
- An accepted agent action appears as `command.npc_action`, then receives a
  bounded response/ack and is archived.
- `/api/state` and `/api/history/goblin` work; POST control/move/spawn routes
  do not exist.
- A standalone spawn or friendly-body capability failure leaves Goblin in
  `sensor_only`; it never substitutes a normal hostile zombie or falls back to
  a native client.
