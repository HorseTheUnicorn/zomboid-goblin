# Live environment inventory

Inventory captured on 2026-09-03. This document intentionally contains no
credentials, tokens, or secret environment values.

## `.76` — `192.168.0.76`

Role: Goblin AI host.

- The native Project Zomboid client installation at
  `/home/goblin/pz-client/game` was removed at the user's request.
- The Goblin-only SteamCMD tree, user Steam state, client test caches, and
  native-client logs/screenshots were removed at the same time, with no backup.
- No `ProjectZomboid`, `projectzomboid`, `steam`, or `steamwebhelper` process was
  running after removal.
- No native-client systemd unit was present in the inventory. The remaining
  enabled services are the existing Goblin agent/relay, Qwen, bot, observatory,
  payout signer, and VNC session services.
- The separate `/home/goblin/pz-client/server` directory was retained. It is
  not a Goblin multiplayer client and was not used as a deletion target.
- The system-wide `/usr/games/steam` executable remains installed because it
  was not identified as a Goblin-only dependency.
- The existing bridge relay uses the pre-provisioned local bridge mount and
  connects to `.03` over the key-only SSH relay configuration.

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
- `GoblinSurvivor` is present in the active `Mods=` loadout as the original
  server-side vanilla-adapter package. The old GoblinSurvivor Workshop copy is
  not required by the active configuration.
- `Bandits2` and Workshop item `3268487204` were removed from the active
  `Mods=`/`WorkshopItems=` loadout after the standalone adapter was verified.
  The Bandits cache remains on disk as a recoverable historical artifact and
  is not loaded by the server.
- The server was healthy during inventory: `zomboid-servertest.service` was
  active, `ProjectZomboid64 -servername servertest` was running, and UDP ports
  `16261` and `16262` were bound.
- The server's existing save and other mod loadout were left in place. The
  standalone swap used the bounded backup directory
  `/home/zomboid/backups/goblin-standalone-7acd912/` before the restart.

## Operational boundary

The `.76` removal did not touch the `.03` installation, save, configuration,
Workshop cache, or running server. Server-side mod changes require a separate
review and a small, timestamped safety backup before deployment.
