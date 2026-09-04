# Deployment

## Hosts

`.03` is the dedicated PZ Build 42 server. `.76` runs the Python agent,
relay, local Qwen, and tracker. Use the Proxmox web console for `.03`; do not
depend on a direct SSH path to the container.

## Server-side mod

Install the `GoblinSurvivor` package under the server's Build 42 mod path and
enable it together with Bandits2. Bandits2 Workshop item `3268487204` is a
runtime dependency for both the server and joining clients. Put `Bandits2`
before `GoblinSurvivor` in the ordered `Mods=` value and include
`3268487204` in `WorkshopItems=` so Steam clients receive the framework.
The live server's target paths are:

```text
service: zomboid-servertest.service
server: /home/zomboid/pzserver
config: /home/zomboid/Zomboid/Server/servertest.ini
bridge: /home/zomboid/Zomboid/Lua/goblin-bridge
```

For a direct server install, the package root is
`/home/zomboid/Zomboid/mods/GoblinSurvivor` and the B42 files are directly
under its `42/` directory. The repository's `mod/` directory is the Workshop
upload layout; its corresponding local package is
`mod/Contents/mods/GoblinSurvivor`. Do not copy the outer `mod/` directory
into the server's local-mod directory.

The bridge `config.ini` also accepts `GoblinCommanders=Name1,Name2`,
`MinimumBaseGuards=1`, and the bounded `GoblinManagedNpcCount=3` roster
setting. Set the count to `0` when only the protected Goblin body is wanted.
PZ admins and moderators are always accepted as
commanders; ordinary players must be listed explicitly. To set the persistent
base from inside the game, an authorized player sends `!goblin base set`.
That command is resolved and persisted on `.03`; it is not a Qwen command.

Before restarting, take a bounded backup of the server INI, GoblinSurvivor
package, and save. Keep package backups outside `Zomboid/mods` (for example,
under `/home/zomboid/backups`); sibling directories there can be discovered as
additional copies by the PZ mod loader. Do not copy Bandits2 source into this
repository. Restart
only the dedicated-server unit and verify its process and UDP query/game
ports. Inspect the newest DebugLog for Lua errors and confirm the bootstrap
reports `adapter=bandits2 friendly=true control_ready=true`.

## Agent

Provision the bridge root and environment on `.76`, then start
`goblin-zomboid-agent.service.example`. The service is disabled/paused by
default until an operator resumes it. Set `GOBLIN_TRACKER_PORT=8782` if the
default tracker port is unavailable. Set
`GOBLIN_TRACKER_MAP_ROOT=/home/goblin/share/pz-map/b42/muldraugh` after copying
the current server map tile cache to that directory. The tracker serves the
website from the checkout's `web/` directory and serves only bounded map tile
paths from the configured map root. Keep Qwen loopback-only.
For a tunnel origin on the Proxmox host, set the tracker bind explicitly to
`GOBLIN_TRACKER_BIND=192.168.0.76`; otherwise the default loopback bind keeps
the tracker private.

On Windows, keep both forms synchronized from the same revision: the direct
client package is `C:\Users\tomgr\Zomboid\mods\GoblinSurvivor`, while the
Workshop staging package is
`C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor` and contains
`Contents\mods\GoblinSurvivor`.

To refresh the live `.76` checkout without copying secrets, clone the pushed
revision into a new directory, verify the package, and update both the agent
and relay units' `WorkingDirectory` values together. Keep the old checkout
until the new service has passed its health checks, then remove it only as a
separate, explicitly approved cleanup.

## Acceptance checks

- `.76` has no native PZ client, Steam GUI session, or gameplay SteamCMD tree.
- PZ writes `runtime.state` with `body_mode=npc`, `npc_id=goblin.primary`,
  `control_ready=true`, and `npc_engine_ready=true` after a player is online.
- PZ reports the managed friendly roster in `runtime.state.npcs`; the exact
  body positions for Goblin, companions, players, and base remain in the
  separate tracker-only telemetry stream.
- `runtime.exact_state` is separate from `runtime.state`.
- An accepted agent action appears as `command.npc_action`, then receives a
  bounded response/ack and is archived.
- `/api/state` and `/api/history/goblin` work; POST control/move/spawn routes
  do not exist; `/` and `/api/map/manifest` serve the read-only tracker UI
  and map metadata.
- A Bandits2 spawn or friendly-body capability failure leaves Goblin in
  `sensor_only`; it never substitutes a normal hostile zombie or falls back to
  a native client.
