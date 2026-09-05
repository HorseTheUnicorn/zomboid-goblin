# Operations

Useful local checks:

```text
systemctl status goblin-zomboid-agent.service goblin-zomboid-relay.service
curl -fsS http://127.0.0.1:8781/healthz
curl -fsS http://127.0.0.1:8782/api/health
curl -fsS http://127.0.0.1:8782/api/state
curl -fsS http://127.0.0.1:8782/api/events
```

On `.03`, use the Proxmox CT console to check:

```text
systemctl status zomboid-servertest.service
ss -lunp | grep -E '16261|16262'
tail -n 200 /home/zomboid/Zomboid/Logs/*DebugLog-server.txt
```

During development, use the disposable Windows profile first:

```powershell
Set-Location 'C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin'
powershell -ExecutionPolicy Bypass -File .\tools\Sync-LocalPz.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzServer.ps1
```

The local server uses `goblin-local`, ports `16271/16272`, and a separate
multiplayer save. Stop it with `tools\Stop-LocalPzServer.ps1` before syncing
files again. Read the local PZ server log and the bridge runtime files under
`C:\Users\tomgr\Zomboid\Lua\goblin-bridge`.

The native adapter fails closed. If the native spawn or friendly-body
contract is unavailable, stop issuing commands and inspect the current Build
42 server log. If Goblin is absent after a clean local restart, keep the
server running with a player online long enough for the server-side spawn
anchor to become available, then inspect the single bounded spawn diagnostic
in the newest `*DebugLog-server.txt`.

Never place Steam, PZ server, VNC, Qwen admin, or bridge credentials in shell
arguments, logs, chat, tracker state, or browser URLs.
