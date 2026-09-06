# Local Windows PZ testing

Use the Windows Build 42 installation and the disposable `goblin-local`
profile for development. This loop is separate from production `.03` and
does not require a native PZ client on `.76`.

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

The installed game is Build 42.20.4. The disposable profile uses
`Mods=GoblinSurvivor`, an empty `WorkshopItems=`, `PauseEmpty=false`, and a
separate multiplayer save. The empty Workshop list is intentional: local
iteration uses the synchronized direct package and does not wait for a
Workshop download.

## Use the `.76` Goblin brain from the Windows test server

The local PZ server should reach the `.76` bridge, not the raw Qwen HTTP
endpoint. Qwen stays private on `.76` at `127.0.0.1:8000`; the Python agent
reads it locally, validates its output, and exposes only typed bridge files.
This is the same boundary that production `.03` will use. For the local
harness, the relay runs on Windows and reverses the normal production
direction: it pushes PZ events/results/state to `.76` and pulls typed
commands back.

The Windows-to-`.76` test relay requires key-only OpenSSH access to the
pre-provisioned `goblin` account on `.76`. It does not copy passwords or
tokens and it does not use a PZ/Steam client on `.76`. First verify that the
`.76` host's SSH service is reachable and that the key is already trusted:

```powershell
Test-NetConnection 192.168.0.76 -Port 22
ssh -p 2222 -i "$env:USERPROFILE\.ssh\id_ed25519_goblin" goblin@192.168.0.76 true
```

Then run the local relay in a separate PowerShell window while the `.76`
agent and its local Qwen service are enabled:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalGoblinRelay.ps1
```

The helper defaults to the existing Windows key at
`C:\Users\tomgr\.ssh\id_ed25519_goblin`; pass `-SshKey` only when the key is
stored elsewhere. The `.76` SSH service uses port `2222`; pass `-SshPort 22`
only when the host's SSH listener is configured on the standard port. The
private key itself must remain outside the repository.

For a one-pass connectivity check, use `-Once`. The helper's remote root is
`/home/goblin/zomboid-goblin-local/bridge` by default because the `goblin`
account cannot create siblings beneath the root-owned `/mnt` directory. A
separate `.76` local-test agent must use that root; do not point the
production `.76` relay at it or point the local relay at
`/mnt/goblin-zomboid`, because that would mix `.03` and local events. If a
different user-owned path is used, pass the same path to both the helper's
`-RemoteBridgeRoot` parameter and the agent's `GOBLIN_BRIDGE_ROOT` setting.
For production, `.76` runs its existing relay toward `.03`, and `.03` still
does not need direct access to port `8000`.

On `.76`, keep the agent's Qwen URL loopback-only and enable the agent only
after the local acceptance gates are ready. The required service settings
are `GOBLIN_QWEN_URL=http://127.0.0.1:8000`, `GOBLIN_ENABLED=true`, and an
operator-controlled `GOBLIN_START_PAUSED` value. Do not bind Qwen to
`0.0.0.0` or publish port `8000` to the LAN.

## Synchronize and launch

Run PowerShell from the repository checkout. Stop the local server and client
before synchronizing; PZ can keep loaded Lua and jar files in memory.

```powershell
Set-Location 'C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin'
powershell -ExecutionPolicy Bypass -File .\tools\Sync-LocalPz.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzServer.ps1 -Storm
```

For the normal visible client:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzClient.ps1 `
    -Storm -Visible -ConnectAddress '127.0.0.1:16271'
```

The helper uses `-nosteam` and PZ's `+connect` launch property. The Storm
client's diagnostic stdout/stderr is under `C:\Users\tomgr\Zomboid\Logs`;
the dated `*DebugLog.txt` is the authoritative PZ log.

The default roster is Goblin plus six companions. To reduce visual and
authority work during a focused Goblin-only smoke test, synchronize with:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Sync-LocalPz.ps1 -ManagedNpcCount 0
```

Do not run synchronization while the server/client are live. Stop them with:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Stop-LocalPzClient.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Stop-LocalPzServer.ps1
```

## Why cold starts are slow

The latest measured run took 278 seconds for the client game-loading state to
finish. The main interval was vanilla `WorldStreamer.isBusy()` inside
`IsoWorld.init` from `10:04:38` to `10:08:22` (about 224 seconds); the
watchdog captured the game-loading thread in `TIMED_WAITING` while all
filesystem queues were empty. The server's login queue completed only after
that world load, at `10:08:24`. The actors were created after world loading
completed, and the local profile has an empty `WorkshopItems=` value, so this
is primarily Build 42's cold map/world-stream initialization—not a Workshop
download or the seven-actor Lua loop.

Keep the same server/client session alive while iterating whenever possible.
Use the single-actor roster for changes that do not need companion coverage.
Do not interpret the watchdog's stall message as a deadlock by itself: the
same run resumed and reported `game loading took 278 seconds`. Keep the same
client/server session alive while iterating whenever possible; restarting the
client repeats this engine-level wait.

## In-world commands

After joining, use PZ chat. The local profile enables these commands for the
development loop:

```text
/gss help
/gss status
/gss follow all
/gss hold all
/gss attack goblin
/gss home all
/gss squad all
/gss dismiss
/gss loot all
/gss scavenge all
/gss disassemble all
/gss build Mike
/gss guard Bob
```

Selectors accept `all`, an NPC id such as `npc.mike`, or a display name such
as `Mike` (case-insensitive). A job command changes server task metadata; a
job is not validated until the corresponding body movement/work counter or
world effect is observed. A bridge request with a fabricated authority token
must remain rejected.

## Evidence to collect

Bridge state:

```powershell
Get-Content -Raw 'C:\Users\tomgr\Zomboid\Lua\goblin-bridge\runtime\zomboid-state.json'
Get-Content -Raw 'C:\Users\tomgr\Zomboid\Lua\goblin-bridge\runtime\zomboid-exact-state.json'
```

Server authority and body creation:

```powershell
$log = Get-ChildItem 'C:\Users\tomgr\Zomboid\Logs' -Filter '*DebugLog-server.txt' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
rg -n 'client-survivor authority ready|authoritative human body created|human survivor died|route actor=|local combat fixture' $log.FullName
```

Client construction/rendering:

```powershell
$log = Get-ChildItem 'C:\Users\tomgr\Zomboid\Logs' -Filter '*DebugLog.txt' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
rg -n 'created Java human survivor actor|render state:|hair=Spike|firearm=Base.AssaultRifle2' $log.FullName
```

The expected visual evidence is a `HumanSurvivor` class, `isZombie=false`,
and render diagnostics showing an active model/object-list membership. Do not
use `body_present=true` in server telemetry as proof that the client rendered
the actor.

## Two-client test

Stage a separate cache only after the first client is stopped if the goal is
to re-run a clean single-client load; use `-AllowMultiple` only for the
parallel test:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Stage-LocalPzClientCache.ps1 `
    -TargetPzDataRoot 'C:\Users\tomgr\Zomboid\goblin-local-client-2'
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzClient.ps1 `
    -Storm -Visible -AllowMultiple `
    -PzDataRoot 'C:\Users\tomgr\Zomboid\goblin-local-client-2' `
    -CacheDir 'C:\Users\tomgr\Zomboid\goblin-local-client-2' `
    -LogPrefix 'goblin-local-client-2' `
    -ConnectAddress '127.0.0.1:16271'
```

The isolated cache prevents file/log collisions but does not create a new
multiplayer username. Enter a distinct username in the second client's
native login flow. A duplicate-username rejection is a failed probe, not a
multiplayer synchronization result.

## Release boundary

Local success is necessary but not sufficient for Workshop publication or a
production rollout. Keep `.03` unchanged until rebind, two-client,
behavior-level jobs, combat, chat/Qwen, and package checks pass. Never put
credentials or authority tokens in shell arguments, logs, chat, or tracker
state.
