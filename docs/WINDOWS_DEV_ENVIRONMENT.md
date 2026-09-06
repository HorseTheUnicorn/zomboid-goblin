# Windows development environment

Verified for the local Build 42.20.4 installation on 2026-09-05.

## Source of truth

```text
C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin
```

The visible OneDrive `GoblinSurvivor` folder is not the active checkout.

## Project Zomboid paths

```text
Install:       C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid
Client exe:    C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.exe
Server Java:   C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\jre64\bin\java.exe
Game jar:      C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\projectzomboid.jar
PZ data:       C:\Users\tomgr\Zomboid
Direct mod:    C:\Users\tomgr\Zomboid\mods\GoblinSurvivor
Workshop copy: C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor
Bridge:        C:\Users\tomgr\Zomboid\Lua\goblin-bridge
Local profile: C:\Users\tomgr\Zomboid\Server\goblin-local.ini
Logs:          C:\Users\tomgr\Zomboid\Logs
```

The local server uses game/query port `16271` and UDP `16272`. The local
profile is separate from `.03`, has an empty `WorkshopItems=`, and loads only
the standalone GoblinSurvivor package.

## Repeatable loop

```powershell
Set-Location 'C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin'
powershell -ExecutionPolicy Bypass -File .\tools\Sync-LocalPz.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzServer.ps1 -Storm
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzClient.ps1 -Storm -Visible -ConnectAddress '127.0.0.1:16271'
```

Stop both processes before replacing a loaded package. Keep the same session
alive during iteration because the latest cold Build 42 client load measured
278 seconds, mostly waiting in vanilla `WorldStreamer.isBusy()` /
`IsoWorld.init`. Use
`-ManagedNpcCount 0` for an actor-only smoke test.

## Current gates

Single-client human visibility, render registration, Goblin follow movement,
ranged combat, death/recreation, fixed hair, and firearm readiness are
verified. Two-client identity, jobs with world effects, melee, unload/rebind,
reconnect, companion/squad behavior, and the final chat/Qwen path are not.

Never use the Windows harness as Goblin's production client, and never point
the local scripts at `.03` data or ports.
