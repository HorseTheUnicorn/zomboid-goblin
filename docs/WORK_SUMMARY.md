# Current work summary

Goblin is a persistent, server-side Project Zomboid NPC. .03 owns the
networked body and exact world actions; .76 owns Qwen, the Python
controller/relay, durable memory, and the read-only tracker. The native PZ/Steam
client concept was removed from .76 without backups as requested.

The intended body stack is now explicit: Bandits2 Workshop item 3268487204 is
the required NPC framework on .03 and joining clients. GoblinSurvivor's
BanditsAdapter.lua is the only Bandits2-specific boundary. It creates or
restores the goblin.primary profile through BanditCustom, uses
BanditServer.Spawner.Individual for one body, runs the verified Companion
program, and reapplies friendly/protected state. There is no vanilla adapter
fallback.

The Python side already has a typed NpcBodyDriver, strict intent validation,
deterministic safety/entity/squad/base-job gates, bounded SQLite telemetry, and
the atomic filesystem bridge. The Lua side has bounded spawn/rebind behavior,
protection hooks, separate coarse/exact telemetry, semantic target resolution,
chat forwarding, a narrow nearest-zombie combat bridge, and Bandits2-backed
settlement assignment persistence for jobs, guards, and squads.

The `.76` agent/relay runtime remains at revision `623f3c1`; the follow-up
`ecb40f4` change is the Bandits2-backed mod package and does not change the
Python runtime. The `.03` server package and the Windows client package are
now at `ecb40f4`. The dedicated servertest profile advertises Workshop item
`3268487204` and loads `Bandits2` before `GoblinSurvivor`; the server was
restarted and its fresh log reports `adapter=bandits2 friendly=true
control_ready=true`. Goblin speech now uses the verified Bandits2 body chat
primitive, while the framework's canned `Bandit.Say` helper remains behind
the adapter boundary.

The next live acceptance check is deliberately concrete: join the dedicated
server with a client that has both Workshop packages. The bridge state must
eventually show `body_mode=npc`, `control_ready=true`, and
`npc_engine_ready=true` after a player is online.

Local checks cover strict bridge behavior, semantic coordinate separation, NPC
command publication, deterministic squad/job policy, and tracker read-only
routes. A live restart and in-world spawn/movement/chat test remain necessary
before treating the Bandits2-backed milestone as complete.
