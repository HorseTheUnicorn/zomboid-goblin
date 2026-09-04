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

The `.76` agent/relay runtime and read-only tracker now run from the
`58ff9a2` checkout at `/home/goblin/zomboid-goblin-58ff9a2`; this includes the
B42 map UI, bounded tile routes, HEAD support, and the managed-friendly roster.
The `.03` server package and the two direct local Windows package paths are
now synchronized from the same `58ff9a2` revision. The running Windows client
must be restarted before testing this roster build; other users still need the
exact corresponding Workshop publication. The dedicated servertest
profile advertises Workshop item `3268487204` and loads `Bandits2` before
`GoblinSurvivor`; the server was restarted and its fresh log reports
`adapter=bandits2 friendly=true control_ready=true`. Goblin speech now uses
the verified Bandits2 body chat primitive, while the framework's canned
`Bandit.Say` helper remains behind the adapter boundary.

The old GoblinSurvivor Workshop item `3794624741` was checked and is no longer
available. It is therefore not advertised by the server: the current local
Windows test uses the synchronized direct package, while automatic delivery
to other clients still requires a new unlisted Workshop publication and its
new published-file ID to be added alongside Bandits2.

The important distinction is intentional: GoblinSurvivor is our own mod, and
Bandits2 is its runtime dependency/body engine. We use Bandits2's verified
public API rather than copying or modifying Bandits2 source. The custom policy
and persistence layer is therefore updateable independently while retaining
Bandits2's networked NPC implementation and friendly `Companion` behavior.

The tracker is live on `.76`: `/` returns the read-only website,
`/api/map/manifest` returns the B42 map metadata, and a bounded
`/map/biomemap_<x>_<y>.png` tile returns successfully. The current map layer
still needs in-world landmark calibration once a human player is online.

The next live acceptance check is deliberately concrete: join the dedicated
server with a client that has both Workshop packages. The bridge state must
eventually show `body_mode=npc`, `control_ready=true`, and
`npc_engine_ready=true` after a player is online.

Local checks cover strict bridge behavior, semantic coordinate separation, NPC
command publication, deterministic squad/job policy, and tracker read-only
routes. A live restart and in-world spawn/movement/chat test remain necessary
before treating the Bandits2-backed milestone as complete.
