# Live environment inventory

Inventory captured on 2026-09-04. This document intentionally contains no
credentials, tokens, or secret environment values.

## `.76` — `192.168.0.76`

Role: Goblin AI host.

- The native Project Zomboid client installation at
  `/home/goblin/pz-client/game` was removed at the user's request.
- The Goblin-only SteamCMD tree, user Steam state, client test caches, and
  native-client logs/screenshots were removed at the same time, with no
  backup.
- No `ProjectZomboid`, `projectzomboid`, `steam`, or `steamwebhelper` process
  was running after removal.
- The separate `/home/goblin/pz-client/server` directory was retained. It is
  not a Goblin multiplayer client and was not used as a deletion target.
- The existing bridge relay uses the pre-provisioned local bridge mount and
  connects to `.03` over the key-only SSH relay configuration.
- The `.76` agent/relay/tracker remains the production control plane. It does
  not run a native PZ gameplay client.
- The B42 tracker map cache is installed read-only at
  `/home/goblin/share/pz-map/b42/muldraugh`; the tracker UI is served from the
  deployed checkout.

## `.03` — `192.168.0.3` / Proxmox CT100

Role: Project Zomboid dedicated server.

- The live server installation is `/home/zomboid/pzserver`.
- The systemd unit is `zomboid-servertest.service` and starts
  `/home/zomboid/pzserver/start-server.sh --servername servertest`.
- The live game build observed in the server logs is `42.20.4`.
- The server configuration is `/home/zomboid/Zomboid/Server/servertest.ini`.
- The active multiplayer save is under
  `/home/zomboid/Zomboid/Saves/Multiplayer/servertest`.
- The bridge endpoint is `/home/zomboid/Zomboid/Lua/goblin-bridge`.
- Production has not been migrated to the new native NPC engine during this
  local development pass. The existing production package/loadout and save
  remain in place, and no production restart is part of local testing.
- GoblinSurvivor remains installed at the direct server path
  `/home/zomboid/Zomboid/mods/GoblinSurvivor/42` until the tested native
  package is staged for a separately guarded rollout.
- The previously used published Workshop item is unavailable, so it is not
  advertised by the server. A new unlisted GoblinSurvivor publication is
  required before automatic client delivery can be enabled.
- Existing server backups remain outside `Zomboid/mods` under
  `/home/zomboid/backups`.

## Windows project and local PZ harness

The active Windows Git project is:

```text
C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin
```

The local installation is:

```text
PZ install: C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid
PZ data:    C:\Users\tomgr\Zomboid
Build:      42.20.4
profile:    goblin-local
ports:      16271/16272
```

The sync helper installs the direct package at
`C:\Users\tomgr\Zomboid\mods\GoblinSurvivor`, refreshes the Workshop
staging copy at `C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor`, creates
the local bridge at `C:\Users\tomgr\Zomboid\Lua\goblin-bridge`, and
provisions a separate `goblin-local` server profile. The start helper runs
only the local Java dedicated server. It never contacts `.03` and never
changes the `.03` save.

## Operational boundary

Local code and local PZ data are disposable test state. Do not copy a local
save or bridge credentials into the repository. Future production changes
require a separate review and a small, timestamped safety backup outside
`Zomboid/mods` before deployment.
