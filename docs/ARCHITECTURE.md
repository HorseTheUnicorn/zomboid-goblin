# Architecture

Goblin has three isolated planes:

1. **PZ server (`.03`)** — `GoblinRuntime` owns one networked `IsoZombie`.
   `GoblinSpawner` persists and binds `goblin.primary`, `GoblinBody` applies
   the human/friendly invariants, `GoblinBrain` selects tasks, and
   `GoblinMovement` delegates all navigation to `PathFindBehavior2`.
2. **Agent (`.76`)** — Qwen receives the redacted `brain_view`, proposes one
   typed high-level intent, and Python applies reflex/safety/entity gates
   before publishing `command.npc_action` through the existing file bridge.
3. **Tracker (`.76`)** — exact coordinates are retained in the separate
   tracker stream and read-only APIs. They are never copied into Qwen context.

The filesystem bridge writes JSON before its ready marker. Request IDs,
message sizes, timestamps, and archive/dead-letter transitions are bounded;
the PZ tick never waits for Qwen, Discord, or the web server.

```text
PZ events -> coarse runtime.state -> Qwen -> validated intent
    -> deterministic Python gate -> NpcBodyDriver
    -> command.npc_action -> GoblinBridge
    -> GoblinBrain -> PathFindBehavior2 -> one IsoZombie

PZ exact state ----------------------------------> tracker/map only
```

The companion's stable body class is deliberately `IsoZombie`, because that
is the supported Build 42 networked entity path. It is humanized once with a
named Survivor outfit, the packaged `Goblin_MysteryBody` `base:fullsuit`
clothing item, and custom conditional `Bob_Idle`, `Bob_Walk`, `Bob_Run`, melee,
face-target, hit-reaction, stagger, and get-up nodes. `GoblinMoveType`,
`GoblinCombatState`, `GoblinPhysicalState`, and `GoblinNPC` are replicated
animation variables; ordinary zombies never satisfy those
conditions. `ATTACK` uses native pathing plus a delayed real `Hit()` call at a
bounded range, and `LOOT` transfers only existing world items in a bounded
loaded-square scan. No client-side animation forcing, coordinate
interpolation, player account, or native fence-climb state is part of the
controller.

The optional Qwen/Discord process can be offline without disabling the local
companion. An offline persisted owner pauses respawn rather than transferring
ownership to a different player. Duplicate Goblin bodies are removed during
server recovery, and a death cooldown prevents spawn storms.
