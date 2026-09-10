# Operations

Useful checks on `.76`:

```text
systemctl status goblin-zomboid-agent.service goblin-zomboid-relay.service
curl -fsS http://127.0.0.1:8781/healthz
curl -fsS http://127.0.0.1:8782/api/health
curl -fsS http://127.0.0.1:8782/api/state
curl -fsS http://127.0.0.1:8782/api/events
```

On `.03`, use the Proxmox console to check:

```text
systemctl status zomboid-servertest.service
ss -lunp | grep -E '16261|16262'
tail -n 200 /home/zomboid/Zomboid/Logs/*DebugLog-server.txt
```

At startup the server should log `adapter=iso_zombie`. With a player online,
the first spawn should log one `SPAWN` line containing
`id=goblin.primary`; subsequent ticks must not create another body. A death
logs `RECOVERY` and waits for the configured cooldown. If the owner is offline,
the recovery loop remains paused rather than transferring ownership.

Never place Steam, PZ server, Qwen admin, or bridge credentials in shell
arguments, logs, chat, tracker state, or browser URLs. Do not issue direct
coordinate commands through Qwen; use the authorized in-game `/goblin debug`
path for deterministic developer checks.
