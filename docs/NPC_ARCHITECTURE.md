# NPC architecture

`goblin.primary` is the sole stable Goblin identity. `NPCRegistry` binds that
identity to a server-created, networked body marked with this mod's own
`getModData()` fields. It scans the loaded zombie population after restarts
and requests one replacement through the Build 42 server spawn API when an
online player anchor exists. `GoblinNPC` exposes the narrow profile/state
surface used by telemetry and commands.

The execution path is:

```text
ValidatedIntent -> SafetyController -> SafeAction -> NpcBodyDriver
-> command.npc_action -> CommandLoop -> ActionExecutor -> NpcAdapter
```

`NpcAdapter` exposes the self-contained `VanillaNpcAdapter` implementation.
Its small survivor-style brain was shaped from the validated Bandits2
behavior, but it is implemented in this repository and does not load Bandits2
globals or assets. It sets friendly and companion policy fields, applies the
optional survivor/immortal engine hooks, and requires those fields plus the
target hook before the registry marks the body ready. Protection is reapplied
on every server tick. The adapter deliberately does not mark the body
`useless`, because that population flag could make a persistent NPC eligible
for engine cleanup.

The first combat primitive is deliberately narrow: an approved `ATTACK`
intent can select only the nearest live hostile zombie inside a fixed radius.
Players and friendly GoblinSurvivor bodies are excluded, and the engine target
is restored only for that validated target. Inventory, vehicle, and building
primitives remain rejected until their exact Build 42 contracts are verified.

The client half of this same downloaded mod forwards only local player chat
that mentions Goblin through `OnClientCommand`; the server verifies the
sender's username and emits a bounded, coordinate-redacted chat event. This
is the input path for Qwen replies and does not create a player/account for
Goblin.
