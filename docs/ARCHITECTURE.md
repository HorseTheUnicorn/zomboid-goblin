# Architecture

The system has three deliberately separate planes:

1. PZ server plane (`.03`): GoblinSurvivor runs only on the dedicated server.
   `NPCRegistry` owns the stable `goblin.primary` identity, `Protection`
   maintains the protected profile, `ActionExecutor` resolves semantic actions,
   and `VanillaNpcAdapter` owns the original server-side body integration.
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

The data flow is:

```text
PZ perception -> coarse state -> Qwen -> validated intent
    -> deterministic controller -> NpcBodyDriver
    -> command.npc_action -> Lua ActionExecutor
    -> VanillaNpcAdapter -> persistent NPC body

PZ exact telemetry ---------------------------------> TrackerStore -> map
```

There is no native Steam/PZ gameplay client in this project. Human players
connect normally to the dedicated server and are not required to install a
Goblin control client.

The body adapter uses Build 42's exposed server Lua zombie spawn and movement
surface. It is intentionally not a copy or repackaging of another Workshop
mod; higher-level companion, combat, inventory, and building behaviors remain
owned by this repository and are enabled only after their engine contracts are
validated.
