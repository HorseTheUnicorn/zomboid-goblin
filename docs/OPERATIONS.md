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

If the server reports that the Bandits adapter is unavailable, stop issuing
commands and inspect the installed Workshop package/API notes. The adapter is
designed to fail closed. If the Goblin is absent, keep the server running with
players online long enough for the Bandits individual spawn anchor to become
available; the registry retries and persists the stable identity.

Never place Steam, PZ server, VNC, Qwen admin, or bridge credentials in shell
arguments, logs, chat, tracker state, or browser URLs.
