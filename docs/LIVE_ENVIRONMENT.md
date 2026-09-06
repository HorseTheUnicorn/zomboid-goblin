# Live environment inventory

Inventory captured on 2026-09-06. This document intentionally contains no
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
- A guarded rollout completed on 2026-09-06. The active package at
  `/home/zomboid/Zomboid/mods/GoblinSurvivor/42` is the package built from
  commit `5b5f640`; its Storm jar SHA-256 is
  `798d29dea9d11d45ca83ebc6e6f4e649db6275d8bb67d995f3bcf919f4ce3253`.
- The active server loadout contains `GoblinSurvivor` only. The previous
  package, configuration, save, and removed Workshop cache remain in the
  timestamped recovery directory
  `/home/zomboid/backups/goblinsurvivor-20260906-231020`.
- The unlisted Workshop item `3797127671` is published under
  `HorseTheUnicorn`, but it is not currently in `.03`'s `WorkshopItems=`.
  A prior server-side download attempt failed before installation, so the
  production server currently uses the verified direct package. Re-test
  Workshop delivery before enabling automatic client download.
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
