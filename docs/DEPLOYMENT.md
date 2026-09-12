# Deployment

`.03` is the dedicated PZ server. `.76` hosts Qwen and may also run the Python
daemon/SSH file relay. Remote deployment is separate from local testing; these
instructions do not imply the remote server has been changed.

## Server and clients

Use PZ **42.20.4** and a matching Storm server release. Install the complete
`mod/Contents/mods/GoblinSurvivor` directory on the server and enable
`GoblinSurvivor`. Start the dedicated server through Storm's server launcher or
its server bootstrap (`-javaagent:.../storm-bootstrap.jar -Dstorm.server=true`).
It loads `42/goblin-server.jar`; look for:

```text
[GoblinSurvivor] SERVER_JAVA_READY inventory=native jobs=craft,repair atomic_ipc=true client_hooks=none
[GoblinSurvivor] PASSENGER_SEAT_GUARD ready=true
[GoblinSurvivor] runtime ready engine=iso_zombie mode=one-goblin-per-player
```

**Clients do not need Storm.** Each ordinary client needs the same Goblin
Lua/assets through your chosen direct/Workshop distribution. The vanilla game
does not load the server helper without Storm. No client Java patches are used.

The crafting adapter is tied to the installed 42.20.4 native method signatures.
It runs native ingredient/output phases without the public crafting method's
unconditional IsoPlayer XP/history casts. The repair adapter uses native fixer
costs and success/condition rules without player-only XP. No hidden player is
created and no global recipes are changed. Passenger support adds two server-only
packet validation guards: a player's entry/seat-switch packet cannot displace a
Goblin already in that seat. Boarding fails closed if those guards are missing.
Rebuild and run `CompanionJobsTest` and `CompanionSeatsTest` against the target game/Storm jars after game updates; an
unverified game update is not a safe production deployment.

To rebuild the platform-independent helper jar on Windows with JDK 25:

```powershell
powershell -ExecutionPolicy Bypass -File tools/Build-GoblinServer.ps1 -Jdk 'C:/path/to/jdk-25' -StormJar 'C:/path/to/storm-42.20.4.jar'
```

Inventory snapshots live in the active world's `goblin-companions/`, not the
IPC bridge. Back up that directory with the world save. Corrupt/newer snapshots
stop restoration rather than silently discarding possessions. Abrupt crashes
can lose changes since the last checkpoint; world and inventory updates are
not one filesystem transaction.

## SteamCMD publication

Use `tools/SteamCMD-GoblinSurvivor.vdf` to update existing Workshop item
`3797199625`. Edit its local staging path if necessary. Its `contentfolder`
must end at `GoblinSurvivor/Contents`, so the downloaded item contains
`mods/GoblinSurvivor/42/mod.info` directly. Uploading the parent folder creates
an extra `Contents` layer that the game's ordinary mod discovery does not load.

After staging the tested package, run SteamCMD with `+login <your-account>` and
`+workshop_build_item <absolute-path-to-the-vdf> +quit`. Authenticate privately
in SteamCMD if prompted; do not put passwords in a script. The checked-in VDF
intentionally omits preview, title, description and visibility keys to preserve
the Workshop page's existing artwork and metadata on content-only updates.

Keep backups outside every active `mods` folder: renaming a backup directory
does not change the mod ID in its `mod.info`, and it can shadow the Workshop
package. Validate publication with a downloaded package and a server startup
that has no local Goblin fallback. Java-helper readiness alone is insufficient;
the Lua `runtime ready` message and fresh bridge state must also appear.

## Bridge and Qwen

The helper writes only fixed channels under `<PZ cachedir>/Lua/goblin-bridge`.
Keep `GoblinBridgeRoot=goblin-bridge`; arbitrary bridge-root overrides are not
supported by the helper. Provision the marker/channels/config with
`ops/pz-bridge/provision_bridge.sh` after verifying the cachedir and permissions.
Never point the relay at world saves. See `ops/README.md` for the remote relay.

On Linux, keep bridge channels setgid to the provisioned `goblinbridge` group
(mode `2770`). Atomic bridge output uses `0660` so the separate relay account
can read each replacement file. Private companion inventory snapshots still
use owner-only temporary files; do not grant the relay access to world saves.

Both Lua and Python use wire protocol **2**. The historical
`.goblin-bridge-v1` marker names the filesystem layout, not the message version.
Mixed Python/Lua versions are rejected. Update them together.

Run `python -m goblin_zomboid.daemon`. Deliberately set `GOBLIN_ENABLED=true`
and `GOBLIN_START_PAUSED=false` after verifying the bridge root. The heartbeat-
only `python -m goblin_zomboid` entry point does not run Qwen chat. The current
default model alias is `goblin-fast` (`goblin-smart` remains compatible); on `.76`, use
`GOBLIN_QWEN_URL=http://127.0.0.1:8000`.

For local testing, the existing SSH account can tunnel the model service:

```text
ssh -N -L 127.0.0.1:18000:127.0.0.1:8000 -p 2222 -i <dedicated-key> goblin@192.168.0.76
```

Point the local daemon at `http://127.0.0.1:18000` and the local PZ bridge.
Keep Qwen and the admin/tracker APIs on loopback. During HTTP inference the
daemon keeps draining events, acknowledgements and fresh state, so a second
player's chat does not expire behind the first request. Requests remain bounded
and serialized; latency depends on the model server's workload.
Chat events are checked every 250 ms independently of the heartbeat; already
queued chats are drained without a five-second sleep. `CHAT_RESULT` logs and
the protected admin snapshot retain recent per-owner outcomes/timings.
Spontaneous Lenin-themed remarks use one separate bounded background request;
ordinary addressed chat does not wait for it. Ambient output is speech-only and
is rechecked against the current owner/task before being delivered.

### Resident 8B on the 6 GB RTX 2060

`ops/goblin-llama-8b.service` is the tested `.76` service configuration: one
Qwen3-8B Q4_K_M model, two 8192-token slots, both legacy aliases, non-thinking
generation, quantized KV cache and two CPU threads. It replaces model swapping;
neither Discord functions nor the game API need to select a second model.
The service is limited to two CPU cores, 7 GiB memory high-water/9 GiB maximum,
and 512 MiB swap. This does not change `.03` or its game-server settings.

The original model is not an uncensored fine-tune. The feral Lenin persona lives
in game prompts, independently of Discord. No unverified alternate weights are
automatically downloaded. `tools/check_qwen_runtime.py` checks concurrent game
responses and tool-call JSON without sending game/Discord messages or executing
tools. Initial checks on `.76`: 2.27–2.43 s simultaneous replies, 0.71 s tool call.
These are smoke-test timings, not a latency guarantee under every workload.

The 35B cache was removed after the 8B checks; configuration backups are at
`/home/goblin/llama-8b-backup-20260911-wlbtjY/`. Its removed Hugging Face revision
is `ggml-org/Qwen3.6-35B-A3B-GGUF@baec3ebee244827cda0f4557eafa8b28f7545fa6`.
Recovering the old route requires redownloading those weights as well as restoring
the original service unit. Discord credentials, memory and functions are not part
of this model cleanup.

## Acceptance before release

- Two ordinary clients get one named companion each, never an adopted zombie.
- Each follows its moving owner, starts chores after 30 seconds stationary,
  and returns when movement resumes. Explicit orders and five-tile defense persist.
- Running/sprinting starts Goblin running at short gaps too; spacing is 3 tiles.
  Empty searches explore new loaded waypoints, and blocked doors/windows are
  opened only when unlocked and unbarricaded. Check both map and minimap markers.
- A new character after death recalls the same named Goblin and inventory;
  test both a nearby run and a distant relocation with network ownership on a client.
- Real loot is delivered at the owner's current feet, or their set base. With no
  base and an offline owner, cargo is retained. Delivered piles are not re-looted
  by automatic chores. `/goblin base clear` restores feet-first delivery.
- Skin, clothes, facing, human attack/climb animations and overhead names look
  correct on both clients.
- Approaching a ready Goblin does not play the one-shot zombie surprise sting;
  a newly spotted ordinary zombie still can. This client-local exclusion does
  not mute the game's separate adaptive threat music.
- A house curtain order visits the owner's building, including other rooms and
  floors, closes accessible curtains, and reports blocked/unloaded targets.
  Check door opening, safe closing behind Goblin, and cancellation mid-job.
- Both players receive Qwen replies as their own named Goblin, including when
  messages overlap during slow inference.
- Reconnect, logout, ownership handoff and restart preserve identity/inventory.
  Loaded offline companions can work; unloaded cells do not fabricate work.
- Real loot, material consumption, barricades and supported construction are
  verified. Separate Goblin errors from vanilla startup noise.

Do not release on the strength of unit tests or a Blender render alone.
