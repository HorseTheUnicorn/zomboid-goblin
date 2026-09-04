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

The active server loadout must include `Bandits2` before `GoblinSurvivor`, and
the Workshop item `3268487204` must be present in `WorkshopItems=`. If the
server reports that the Bandits2 API or the friendly brain contract is
unavailable, stop issuing commands and inspect the current Build 42 server log
before changing the loadout. The adapter is designed to fail closed: it will
not substitute a normal hostile zombie. If the Goblin is absent after a clean
restart, keep the server running with a player online long enough for the
server-side spawn anchor to become available, then inspect the single bounded
spawn diagnostic in `*DebugLog-server.txt`.

Never place Steam, PZ server, VNC, Qwen admin, or bridge credentials in shell
arguments, logs, chat, tracker state, or browser URLs.
