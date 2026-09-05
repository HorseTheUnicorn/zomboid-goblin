# Deployment

## Hosts

`.03` is the dedicated PZ Build 42 server. `.76` runs the Python agent,
relay, local Qwen, and tracker. Use the Proxmox web console for `.03`; do not
depend on a direct SSH path to the container.

The Windows checkout and local PZ installation are the development harness.
They are separate from the production `.03` save and are the first place to
test a mod change.

## Self-contained server mod

GoblinSurvivor is a single self-contained mod. It creates and controls its
own native Build 42 bodies and has no external NPC framework or required body
engine. The server's ordered loadout contains only `GoblinSurvivor` for this
feature, and `WorkshopItems=` remains empty until the new unlisted
GoblinSurvivor Workshop item is published.

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

The bridge `config.ini` accepts `GoblinEnabled=true`,
`GoblinCommanders=Name1,Name2`, `MinimumBaseGuards=1`, and the bounded
`GoblinManagedNpcCount=6` roster setting. Set the count to `0` for a Goblin-only
local spawn test when only the protected Goblin body is wanted. PZ admins and
moderators are always accepted as commanders; ordinary players must be
listed explicitly. To set the persistent base from inside the game, an
authorized player sends `!goblin base set`.

## Production rollout

Do not touch `.03` while developing locally. After the local profile passes
the native spawn, friendly-filtering, movement, speech, persistence, and
death-recovery checks:

1. Take a bounded backup of the server INI, GoblinSurvivor package, and save.
   Keep backups outside `Zomboid/mods` (for example, under
   `/home/zomboid/backups`); sibling directories there can be discovered as
   additional copies by the PZ mod loader.
2. Install the exact tested `GoblinSurvivor` package under the direct server
   path and set `Mods=GoblinSurvivor`.
3. If the Workshop item has been published, add only its new numeric ID to
   `WorkshopItems=`. Do not invent or reuse an unavailable published-file ID.
4. Restart only the dedicated-server unit with no players connected.
5. Verify the process and UDP query/game ports, inspect the newest
   `DebugLog`, and confirm bootstrap reports `adapter=native`.

The `.03` migration is a separate guarded operation. A local test failure
must never trigger a production restart or alter the production save.

## Agent

Provision the bridge root and environment on `.76`, then start
`goblin-zomboid-agent.service.example`. The service is disabled/paused by
default until an operator resumes it. Set `GOBLIN_TRACKER_PORT=8782` if the
default tracker port is unavailable. Set
`GOBLIN_TRACKER_MAP_ROOT=/home/goblin/share/pz-map/b42/muldraugh` after copying
the current server map tile cache to that directory. Keep Qwen loopback-only.
For a tunnel origin on the Proxmox host, set the tracker bind explicitly to
`GOBLIN_TRACKER_BIND=192.168.0.76`; otherwise the default loopback bind keeps
the tracker private.

On Windows, keep both forms synchronized from the same revision: the direct
client package is `C:\Users\tomgr\Zomboid\mods\GoblinSurvivor`, while the
Workshop staging package is
`C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor` and contains
`Contents\mods\GoblinSurvivor`. The exact sync/start commands are in
`docs/LOCAL_TESTING.md`.

## Acceptance checks

- `.76` has no native PZ client, Steam GUI session, or gameplay SteamCMD tree.
- The Windows local profile loads only `GoblinSurvivor` and uses a separate
  port/save from `.03`.
- PZ writes `runtime.state` with `body_mode=npc`,
  `npc_id=goblin.primary`, `control_ready=true`, and
  `npc_engine_ready=true` after a player is online.
- PZ reports the managed friendly roster in `runtime.state.npcs`; exact body
  positions for Goblin, companions, players, and base remain in the separate
  tracker-only telemetry stream.
- `runtime.exact_state` is separate from `runtime.state`.
- An accepted agent action appears as `command.npc_action`, then receives a
  bounded response/ack and is archived.
- `/api/state` and `/api/history/goblin` work; POST control/move/spawn routes
  do not exist; `/` and `/api/map/manifest` serve the read-only tracker UI
  and map metadata.
- If the native spawn or ownership proof is unavailable, Goblin remains in
  `sensor_only`; the mod never substitutes a normal hostile zombie or falls
  back to a native client.
