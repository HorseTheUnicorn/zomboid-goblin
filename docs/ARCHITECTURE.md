# Architecture

The system has three deliberately separate planes:

1. PZ server plane (`.03`): GoblinSurvivor runs on the dedicated server.
   `NPCRegistry` owns stable identities, `Protection` maintains the protected
   Goblin policy, `ActionExecutor` resolves semantic actions, and
   `NativeNpcAdapter` owns the server-side body and behavior engine.
2. Agent plane (`.76`): Qwen receives `brain_view`, proposes strict JSON, and
   Python applies reflex, combat, entity, job, and squad gates before writing
   a `command.npc_action` bridge message.
3. Tracker plane (`.76`): exact telemetry is retained by `TrackerStore` and
   served through read-only map APIs. This plane is never used to construct
   Qwen context.

The filesystem bridge remains atomic: JSON is written and fsynced before its
ready marker, request IDs are bounded by a ledger, stale/duplicate messages
are archived or dead-lettered, and the PZ tick never waits for Qwen or the web
server.

The model loop is event-driven. A startup transition, meaningful server event,
coarse state transition, or bounded planning interval can request a new Qwen
intent. Ordinary heartbeats refresh telemetry and run deterministic reflexes;
an ongoing native task continues on the server without repeated model calls.

The data flow is:

```text
PZ perception -> coarse state -> Qwen -> validated intent
    -> deterministic controller -> NpcBodyDriver
    -> command.npc_action -> Lua ActionExecutor
    -> NpcAdapter -> friendly persistent native PZ body

PZ exact telemetry ---------------------------------> TrackerStore -> map
```

There is no native Steam/PZ gameplay client in `.76`. Human players connect
normally to the dedicated server. The Windows PZ installation is a local
development/test harness and is not part of Goblin's production runtime.

The body engine is self-contained. It uses the native Build 42
`createZombie(float, float, float, SurvivorDesc, int, IsoDirections)` path with
a friendly survivor descriptor when that surface is available, and the
native `addZombiesInOutfit` API as a bounded compatibility fallback. The body
is marked immediately with GoblinSurvivor `getModData()` fields, and all later
binding requires that marker or a short-lived spawn reservation. A normal
population zombie is never claimed as Goblin.

`NativeNpcAdapter.lua` owns the engine boundary: native pathing, follow tasks,
validated hostile-zombie targeting, chat-line speech, friendly target
clearing, primary-body protection, and native-body persistence. The registry
rebinds marked bodies after a restart and creates a replacement only after a
bounded cooldown. If the native spawn or ownership proof is unavailable, the
mod stays in `sensor_only` and does not expose a normal zombie as Goblin.

Higher-level inventory, vehicle, and building actions remain disabled until
their exact Build 42 contracts are implemented and tested. The adapter does
not pretend that a native body has a weapon, food, water, or medical supplies
when those facts have not been verified.
