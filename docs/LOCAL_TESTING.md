# Local Windows PZ testing

The repository checkout and the installed Windows Build 42 game are now the
development loop. This avoids restarting `.03` for every Lua change. The
local server has its own profile, save, bridge, and ports; it never connects
to or edits the production server.

## Paths

```text
project:       C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin
PZ install:    C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid
PZ data:       C:\Users\tomgr\Zomboid
direct mod:    C:\Users\tomgr\Zomboid\mods\GoblinSurvivor
Workshop copy: C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor
bridge:        C:\Users\tomgr\Zomboid\Lua\goblin-bridge
profile:       goblin-local
ports:         16271 (game/query), 16272 (UDP)
```

The disposable profile disables UPnP because this loop is localhost-only;
that avoids waiting on router discovery during each restart.

The synchronizer sets `PauseEmpty=false` for this local profile. That is
intentional: the Java survivor authority, independent jobs, ordinary zombie
population, and telemetry must continue advancing while no test client is
connected. This setting is limited to `goblin-local` by the development
workflow and is not a production deployment change.

The current local installation is Build 42.20.4, matching the server-side
mod target. The direct package is used for local iteration; the Workshop copy
is refreshed as a publication-ready staging folder and is not required for
the local dedicated server.

When a player is online, local-only development commands are enabled by the
sync helper. Use the in-game chat relay with commands such as:

```text
/gss spawn test
/gss list
/gss inspect dev.test.001
/gss follow dev.test.001 <your-player-name>
/gss hold dev.test.001
/gss attacktest dev.test.001
```

These commands are disabled unless both `GoblinDevelopmentMode=true` and
`GoblinAllowTestCommands=true` are present in the disposable local profile.
They are not a production administration interface.

## Sync and start

Run PowerShell from the project directory:

```powershell
Set-Location 'C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin'
powershell -ExecutionPolicy Bypass -File .\tools\Sync-LocalPz.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzServer.ps1 -Storm
```

The sync defaults to `GoblinManagedNpcCount=6`, creating Goblin plus six
additional human companion bodies. Use `-ManagedNpcCount 0` for a Goblin-only
smoke test, or a smaller positive value to exercise a partial roster.

The sync helper refuses to run while the local PZ client or dedicated server
is running. This prevents a loaded Lua module from being replaced underneath
the game. It mirrors only the two exact `GoblinSurvivor` package targets and
stale files left inside those package targets; it does not delete
the PZ data directory or any save.

Stop the local server before another sync:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Stop-LocalPzServer.ps1
```

The local dedicated server and client are launched with `-nosteam` so the
direct-connect test uses the same non-Steam transport on both sides. Start the
client with the repository helper rather than a Steam-mode shortcut:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzClient.ps1
```

To open the normal direct-connect flow automatically for the disposable
server, pass its address at launch:

    powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzClient.ps1 -ConnectAddress '127.0.0.1:16271'

For a human visual check with the Storm client, add `-Storm -Visible` (the
default Storm launch remains hidden/headless for log-driven smoke tests):

    powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzClient.ps1 -Storm -Visible -ConnectAddress '127.0.0.1:16271'

If a Steam-mode client is already open, close it first or run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Stop-LocalPzClient.ps1
```

## In-world test

After the local server is ready, start the Windows PZ client and join
`127.0.0.1` on port `16271`. The client should have the synchronized direct
GoblinSurvivor package. Because `WorkshopItems=` is empty in this disposable
profile, there is no external Workshop dependency or download-order test in
this loop.

With one player online, the server initializes a logical actor near the player
and sends the first `IsoSurvivor` snapshot. Check the server log:

```powershell
Get-ChildItem "$env:USERPROFILE\Zomboid\Logs" -Filter '*DebugLog-server.txt' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Get-Content |
    Select-String 'GoblinSurvivor|NativeNpcAdapter|adapter='
```

The expected server evidence is `body_mode=client_survivor`,
`ClientSurvivorServer: client-survivor authority ready`, and no
`GoblinSurvivorStorm` spawn line. The bridge should then contain runtime files
such
as:

```text
C:\Users\tomgr\Zomboid\Lua\goblin-bridge\runtime\zomboid-heartbeat.json
C:\Users\tomgr\Zomboid\Lua\goblin-bridge\runtime\zomboid-state.json
C:\Users\tomgr\Zomboid\Lua\goblin-bridge\runtime\zomboid-exact-state.json
```

For a first pass, verify in this order:

1. The server loads without Lua errors and reports client-survivor authority.
2. The client log reports `created real client-side IsoSurvivor actor`.
3. The actor is human-rendered and no Goblin `IsoZombie` appears beside the
   player.
4. Follow snapshots move the client actor without a zombie packet or zombie
   target.
5. A movement or speech command remains rejected until the client-actor
   action adapter is implemented; it must not silently fall back to a zombie.
6. Restart only the local profile and confirm a fresh client actor is created
   from a new snapshot.

If local PZ logs expose a different native method shape than the documented
Build 42 surface, record the exact method error and update the adapter plus
the local contract test. Do not move the change to `.03` to diagnose it.

## Manual bridge command

The Python tests cover command publication. For an in-world command, use the
existing agent/relay path or a test fixture that writes a valid
`command.npc_action` message into the local bridge. Do not place credentials
or authority tokens in a shell command. The server still validates every
action and rejects movement messages that contain world coordinates.

## Return to production

Local success is necessary but not sufficient for a production rollout. Keep
`.03` running as-is until the native package, Workshop decision, bounded
backup, no-player window, and guarded restart have each been reviewed.
