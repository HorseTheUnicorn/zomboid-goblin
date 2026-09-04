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
chat forwarding, and a narrow nearest-zombie combat bridge.

The next live acceptance check is deliberately concrete: enable
WorkshopItems=3268487204 and Mods=Bandits2;GoblinSurvivor;... on the dedicated
servertest profile, restart .03, then join with a client that has both
Workshop packages. The server log must report
adapter=bandits2 friendly=true control_ready=true; the bridge state must
eventually show body_mode=npc, control_ready=true, and npc_engine_ready=true
after a player is online.

Local checks cover strict bridge behavior, semantic coordinate separation, NPC
command publication, deterministic squad/job policy, and tracker read-only
routes. A live restart and in-world spawn/movement/chat test remain necessary
before treating the Bandits2-backed milestone as complete.
