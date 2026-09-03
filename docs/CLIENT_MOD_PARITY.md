# Multiplayer client mod parity gate

Goblin cannot join the multiplayer server as a real survivor with only the
server-side `GoblinSurvivor` folder installed. The autonomous client must have
the same Project Zomboid Build 42 version, the complete ordered `Mods=` list,
the complete ordered `WorkshopItems=` list, and the same GoblinSurvivor
content. A human client may be offered Workshop downloads by the server; that
does not prove that the autonomous client on 192.168.0.76 has the files or the
right load order.

## Required contract

The PZ server and the Goblin client must each produce a manifest with exactly
these fields:

```json
{
  "game_build": "42.20.4 b0bbce05d5",
  "mods": ["...", "GoblinSurvivor"],
  "workshop_items": ["1234567890"],
  "goblin_survivor_sha256": "64 lowercase hexadecimal characters"
}
```

`mods` and `workshop_items` are ordered lists. They are compared exactly, not
as sets, because load order affects multiplayer behavior. The content digest
is a deterministic SHA-256 over every file in the GoblinSurvivor mod tree,
including each relative path and its bytes. The Python gate is implemented in
`goblin_zomboid/mods.py`; a claimed `client_mod_parity=verified` field is not
trusted on its own.

Parity is `verified` only when both manifests are present, valid, and equal.
Missing or malformed manifests keep the body unavailable. A build mismatch,
missing Workshop item, missing mod, different order, or different
GoblinSurvivor digest is a hard `mismatch` and must be fixed before a join
test.

## What is installed now

- 192.168.0.3 is running the existing Build 42 server (`42.20.4 b0bbce05d5`).
- The server has the `GoblinSurvivor` mod installed locally and its `Mods=`
  option includes `GoblinSurvivor`; the existing server Workshop/mod loadout
  was preserved, with Workshop item `3794624741` appended for automatic client
  download. The live configuration contains 69 ordered mod entries and 60
  ordered Workshop IDs after the verified restart.
- The Windows workstation has a Steam Project Zomboid client at
  `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid` and the
  Steam Workshop cache at
  `C:\Program Files (x86)\Steam\steamapps\workshop\content\108600`.
  The cache contains 241 item directories, including all 59 existing IDs
  required by the server and the newly published Workshop item `3794624741`.
  A clean join fetched that item into the client-compatible
  `mods\GoblinSurvivor\42` layout.
- The Windows client log reports `42.20.4 b0bbce05d5`, matching the dedicated
  server runtime string. The Steam depot/build IDs are different (`24909800`
  for the client app manifest and `24909836` for the dedicated-server app
  manifest), so the runtime version string and the actual client manifest are
  still required by the parity gate.
- The current reviewed `GoblinSurvivor` tree digest is
  `f0689e22e2f62aad27d706fe22c634c03421c2ece172051f2974e0903c92abef`.
  Any earlier workstation copy or sidecar must be re-staged and must not be
  treated as parity evidence until it matches this digest.
- The Windows client and cache are preparation/evidence inputs only. They are
  not the Goblin client and must not be used as the autonomous body. Goblin's
  real client must run natively on 192.168.0.76. No client runtime manifest or
  `body_present=true` report has been received yet, so the parity/body gate
  remains open.
- A read-only cache audit found 433 cached `mod.info` files and matched all 68
  non-GoblinSurvivor server mod IDs to cached content. `GoblinSurvivor` now has
  the real unlisted Workshop item `3794624741`; its cleanly downloaded Windows
  tree has 16 files and matches the reviewed digest. The server's refreshed
  Workshop cache also uses the root-level `mods\GoblinSurvivor\42` layout and
  loads the mod. This proves neither that the autonomous client has enabled the
  exact ordered loadout nor that the autonomous body is ready.
- `mod/workshop.txt` records the published Workshop ID `3794624741`. The
  server must list that exact numeric ID in `WorkshopItems=` and retain
  `GoblinSurvivor` in `Mods=`. Do not treat the ID alone as parity evidence;
  verify the downloaded tree and digest.

## Installation and verification sequence

When a supported multiplayer client is available on `.76`:

1. Install the exact PZ Build 42 revision used by `.03`.
2. Obtain every Workshop item named by the server's `WorkshopItems=` option
   and install the complete server `Mods=` loadout in the same order. The
   server's existing list plus Workshop item `3794624741` is the source of
   truth; keep `GoblinSurvivor` in the ordered `Mods=` list.
3. Verify the downloaded `GoblinSurvivor` tree against the reviewed digest.
   The local staging helper `ops/native-client/install_goblin_mod.sh` remains
   available for the native `.76` client, but a downloaded package is the
   intended multiplayer distribution path.
4. Generate a server manifest and a client manifest. Run
   `ModParityValidator.from_runtime` with both manifests. Do not bypass a
   `missing`, `invalid`, or `mismatch` result.
5. Start a disposable server with the same loadout, connect the autonomous
   client, and require the runtime to publish both manifests plus
   `body_present=true`. The control plane must then report
   `client_mod_parity=verified`.
6. With a second observing client, test visibility, movement, interaction,
   attack, damage, inventory, death/respawn, save/restart, and reconnect. The
   full checklist is in `BODY_FEASIBILITY_GATE.md`.

Steam credentials, Workshop downloads, and any client installation are
operator-owned inputs. They must not be stored in this repository or in the
bridge. A normal client auto-download prompt is not a substitute for the
manifest and disposable-server evidence.

Until every step passes, keep `GoblinEnabled=false`, keep the deterministic
body driver disabled, and leave Goblin in sensor-only mode.

## Native Linux client boundary

Wine is explicitly out of scope. The `.76` host has an official native Linux
Project Zomboid dedicated-server runtime, but an anonymous SteamCMD validation
of client app 108600 installed zero client bytes (`SizeOnDisk=0` and no
`InstalledDepots`). The native client therefore still needs a legally
authenticated entitlement on `.76`, or a user-provided legal native non-Steam
build. Do not copy Windows Steam credentials, cookies, or license files to the
host.

The supported operator path is documented in `ops/native-client/`. It uses the
existing Steam ownership if the operator manually authenticates SteamCMD on
`.76`; it does not ask for a second account or purchase. `-nosteam` is only a
runtime mode to test after the actual native client files exist, and only with
a compatible server networking mode. It is not a licensing or DRM bypass.

The client adapter runs from `media/lua/client/GoblinSurvivor/ClientHook.lua` and sends only
bounded typed hello/catalog/state reports. Character creation and actions are
rejected until the server has verified the exact manifest and the adapter has
loaded its native Build 42 UI/timed-action surface. No client-side fallback
interprets model output as Lua, shell, coordinates, or raw network data.
