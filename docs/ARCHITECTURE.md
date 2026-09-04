# Architecture

The system has three deliberately separate planes:

1. PZ server plane (`.03`): GoblinSurvivor runs only on the dedicated server.
   `NPCRegistry` owns the stable `goblin.primary` identity, `Protection`
   maintains the protected profile, `ActionExecutor` resolves semantic actions,
   and `NpcAdapter` owns the Bandits2-backed server-side body integration.
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
intent. Ordinary heartbeats only refresh telemetry and run the deterministic
reflex layer; an ongoing Bandits2 task is allowed to continue on the server
without repeated model calls.

The data flow is:

```text
PZ perception -> coarse state -> Qwen -> validated intent
    -> deterministic controller -> NpcBodyDriver
    -> command.npc_action -> Lua ActionExecutor
    -> NpcAdapter -> friendly persistent GoblinSurvivor body

PZ exact telemetry ---------------------------------> TrackerStore -> map
```

There is no native Steam/PZ gameplay client in this project. Human players
connect normally to the dedicated server and are not required to install a
Goblin control client.

The body adapter uses the exact Bandits2 B42.20 API observed on `.03`:
`BanditServer.Spawner.Individual` for one body, `BanditCustom` for the
stable profile, `BanditBrain` for the friendly policy, and Bandits2 movement
tasks. `BanditsAdapter.lua` is the only module that knows those names. If
the Bandits2 API or friendly contract cannot be proven, the mod stays in
`sensor_only` and does not expose a normal hostile zombie as Goblin.
Higher-level combat, inventory, vehicle, and building behaviors remain owned
by this repository and are enabled only after their engine contracts are
validated.
