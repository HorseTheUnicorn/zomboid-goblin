# NPC architecture

`goblin.primary` is the only gameplay NPC identity. `GoblinSpawner` creates a
real Build 42 `IsoZombie` through `VirtualZombieManager.instance` and marks it
immediately in `getModData()`. `OnZombieCreate` adopts only an already-marked
Goblin, so ordinary population zombies can never be claimed accidentally.
The persisted owner is selected once from the first online player; an offline
owner leaves the body in a safe waiting state.

Spawn requests carry a persisted reservation token and next generation before
the native factory is called. On reconnect or reload, the server reconciles
marked bodies by highest `GoblinGeneration` (native id breaks ties), retires
the rest, and expires an abandoned reservation after a short bounded window.
All server and client callbacks use the shared Goblin event registrar, so a
reload cannot leave an older callback able to create or control another body.

The execution path is:

```text
Qwen intent -> Python safety gate -> NpcBodyDriver
    -> command.npc_action -> GoblinBridge validation
    -> GoblinBrain task controller -> GoblinMovement
    -> PathFindBehavior2 -> networked IsoZombie
```

`GoblinBody.lua` is the only module allowed to touch physical body policy. It
sets humanized `Bob_*` animation variables, Survivor outfit, the packaged
`Goblin_MysteryBody` clothing item, display name, friendly/protected flags,
no-bite behavior, weapon identity, and replicated state sequence.
`GoblinMovement.lua` starts/cancels `pathToLocationF` and `pathToCharacter`
goals, uses a stable follow ring, applies walk/run hysteresis, and records
native success/failure. It never writes coordinates each tick, calls
`PlayAnim`, or enters fence/window climb states. Human-gated face-target,
hit-reaction, stagger, and get-up nodes keep recognized transient states out
of the vanilla zombie animation graph.

The task vocabulary is intentionally small: `FOLLOW`, `MOVE_TO`, `WAIT`,
`GUARD`, `ATTACK`, `RETURN_TO_OWNER`, `EQUIP`, `SPEAK`, and `LOOT`. Semantic
Qwen destinations are resolved by the server; exact coordinates are accepted
only by authorized developer commands. `ATTACK` closes with native
`PathFindBehavior2`, plays a conditional Bob melee node, and applies the real
configured Machete through `IsoZombie:Hit()` at a bounded range. `LOOT` scans
only a small loaded-square radius and transfers existing world items; it never
fabricates requested inventory.

The client half only reapplies replicated identity variables and forwards a
local player's addressed chat or `/goblin` developer command. It does not
spawn, move, animate, or own a second body.
