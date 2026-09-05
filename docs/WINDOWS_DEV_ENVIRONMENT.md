# Windows development environment

Verified on 2026-09-04 for the local Build 42 installation.

## Source of truth

The active repository checkout is:

```text
C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin
```

The OneDrive `GoblinSurvivor` directory visible to the desktop workspace is an
empty Git shell and is not the active checkout. Keep edits and commits in the
checkout above until it is deliberately moved or cloned.

## Project Zomboid paths

```text
Install root:
C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid

Client executable:
C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\ProjectZomboid64.exe

Server Java:
C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\jre64\bin\java.exe

Game jar:
C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\projectzomboid.jar

PZ data root:
C:\Users\tomgr\Zomboid

Direct development mod:
C:\Users\tomgr\Zomboid\mods\GoblinSurvivor

Workshop staging:
C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor

Bridge:
C:\Users\tomgr\Zomboid\Lua\goblin-bridge

Local server profile:
C:\Users\tomgr\Zomboid\Server\goblin-local.ini

Logs:
C:\Users\tomgr\Zomboid\Logs

Workshop cache:
C:\Program Files (x86)\Steam\steamapps\workshop\content\108600
```

The installed runtime reports Build `42.20.4 b0bbce05d5`. The local disposable
server uses UDP `16271` and `16272`; check UDP endpoints rather than expecting
a TCP listener.

## Repeatable loop

From the repository root:

```powershell
.\tools\dev-install.ps1
.\tools\Start-LocalPzServer.ps1
.\tools\Start-LocalPzClient.ps1
.\tools\dev-logs.ps1
```

`dev-install.ps1` refuses to sync while the selected PZ client/server is
running. The local configuration enables development mode and `/gss` test
commands. The disposable profile is configured with no Workshop items, so
local testing uses only the standalone native survivor package.

## Local test commands

When an authorized/admin client is connected, send these through PZ chat:

```text
/gss spawn test
/gss list
/gss inspect dev.test.001
/gss follow dev.test.001 <player>
/gss hold dev.test.001
/gss attacktest dev.test.001
```

The test survivor is deterministic and has no Qwen or `.76` dependency.

## Safety

Do not point local scripts at the production `.03` profile. Do not use a
production save for the disposable local world. `dev-package.ps1` refuses to
overwrite an existing output package, and `deploy-03.ps1` requires explicit
SSH identity, destination, and user arguments plus a confirmation step.
