# NPC architecture

`goblin.primary` is the sole required Goblin identity. `NPCRegistry` binds it
to a native, networked `IsoZombie` created with a vanilla survivor descriptor
and marked with GoblinSurvivor-owned `getModData()` fields. It can also
maintain a bounded roster of friendly companions (`npc.sarah`, `npc.bob`, and
other configured entries) through the same native engine. `GoblinNPC` exposes
the narrow state surface used by telemetry and commands.

The execution path is:

```text
ValidatedIntent -> SafetyController -> SafeAction -> NpcBodyDriver
-> command.npc_action -> CommandLoop -> ActionExecutor -> NpcAdapter
```

`NpcAdapter` is a stable facade over `NativeNpcAdapter.lua`. The native engine
creates bodies, sets the survivor visual descriptor, records the stable NPC
identity, clears unsolicited targets, requests pathfinding, and keeps the
friendly/protected policy in force on every update. The adapter does not
depend on a Workshop NPC framework or a second runtime program.

New bodies are accepted only when the native creation call returns the body or
when the `OnZombieCreate` callback matches the adapter's short-lived spawn
reservation. Bodies loaded from a save are accepted only when their own
native GoblinSurvivor marker matches the requested identity. Stale bodies
from an older foreign body implementation are removed during the bounded
rebind scan instead of being silently adopted.

The roster is configured with `GoblinManagedNpcCount` in the provisioned
bridge config. It is bounded to eight entries, spawns only after Goblin has a
verified body, and applies immortal protection only to the primary Goblin. A
dead or unloaded companion is recorded and replacement is delayed and
retry-bounded.

The first combat primitive is deliberately narrow: an approved `ATTACK`
intent can select only the nearest live hostile zombie inside a fixed radius.
Players and friendly GoblinSurvivor bodies are excluded. The native engine
sets only that validated zombie as the combat target and clears the target as
soon as the combat contract ends. Inventory, vehicle, and building primitives
remain rejected until their exact Build 42 contracts are verified.

The client half of this same downloaded mod forwards only local player chat
that mentions Goblin through `OnClientCommand`; the server verifies the
sender's username and emits a bounded, coordinate-redacted chat event. This
is the input path for Qwen replies and does not create a player/account for
Goblin.
