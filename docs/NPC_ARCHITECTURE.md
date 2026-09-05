# Survivor architecture

`goblin.primary` is the required Goblin identity. The configured local roster
also includes Sarah, Bob, Dave, Ellen, Mike, and June. Every entry uses the
same standalone human actor path; Goblin's protection and fixed appearance
are profile capabilities, not a second body implementation.

## Execution path

```text
validated intent -> deterministic controller -> command.npc_action
    -> CommandLoop -> server action validation
    -> ClientSurvivorServer -> ServerSurvivorAuthority
    -> HumanSurvivor Java actor -> bounded client snapshot
    -> ClientSurvivorActor visual actor
```

Python can request semantic actions but cannot write a body coordinate or
select an arbitrary world object. Lua resolves targets and enforces the
server-side safety policy before Java executes the action.

## Body and behavior ownership

`ServerSurvivorAuthority.java` owns the live human object, movement,
generation, firearm, ranged attack, health/death state, and re-creation.
`ClientSurvivorServer.lua` owns the persistent roster record, task/job
metadata, command grammar, snapshot envelope, and bridge integration.
`ClientSurvivorActor.lua` owns only client visual construction and
reconciliation.

The Java actor uses `Base.AssaultRifle2` with a deterministic M14 clip and
`.308` supply. Goblin's hair model is forced to `Spike`. The actor does not
run vanilla needs or a zombie simulation loop.

## Required invariants

- No fake player body.
- No zombie fallback for a missing human actor.
- No adoption of an unrelated population zombie.
- No player target is overwritten by survivor combat code.
- A failed action returns a bounded rejection or failure; it is never reported
  as a fabricated success.
- Development fixtures cannot be invoked from production configuration.

## Remaining implementation work

Melee, smooth movement/collision, the behavior-level job implementations,
guard/hauler/farmer/medic/scout actions, companion/squad behavior, unload and
rebind, two-client synchronization, reconnect, and the final `.76` chat/Qwen
round-trip remain open. Keep release work behind those gates.
