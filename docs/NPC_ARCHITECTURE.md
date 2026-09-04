# NPC architecture

`goblin.primary` is the sole required Goblin identity. `NPCRegistry` binds it
to a Bandits2-created, networked `IsoZombie` body marked with this mod's own
`getModData()` fields. It can also maintain a bounded roster of our own
friendly companions (`npc.sarah`, `npc.bob`, and other configured roster
entries) using the same adapter. It scans the loaded Bandits2 population after
restarts and requests one replacement at a time through
`BanditServer.Spawner.Individual` when an online player anchor exists.
`GoblinNPC` exposes the narrow profile/state surface used by telemetry and
commands.

The execution path is:

```text
ValidatedIntent -> SafetyController -> SafeAction -> NpcBodyDriver
-> command.npc_action -> CommandLoop -> ActionExecutor -> NpcAdapter
```

`NpcAdapter` exposes the required Bandits2 implementation through
`BanditsAdapter.lua`. Bandits2 owns the networked body and `Companion`
behavior; GoblinSurvivor applies the Goblin profile, friendly/loyal/permanent
policy, protection hooks, commands, chat, and persistence. The adapter proves
the exact Bandits2 brain fields before the registry marks the body ready.
Protection and the friendly brain policy are reapplied on every server tick.
There is no vanilla fallback: if the verified Bandits2 API is unavailable, the
mod remains in `sensor_only` and does not expose a normal zombie as Goblin.
The adapter reports the actual Bandits2 task/follow mode and protection proof
to telemetry. Goblin speech uses the framework body chat primitive because
Bandits2's canned `Bandit.Say` helper cannot carry arbitrary Qwen text.

The roster is configured with `GoblinManagedNpcCount` in the provisioned
bridge config. It is bounded to eight entries, spawns only after Goblin has a
verified body, and applies no immortal protection to companions. A dead or
unloaded companion is recorded and replacement is delayed and retry-bounded.

The first combat primitive is deliberately narrow: an approved `ATTACK`
intent can select only the nearest live hostile zombie inside a fixed radius.
Players and friendly GoblinSurvivor bodies are excluded, and the adapter
restores only that validated target while keeping Bandits2's friendly brain
flags. Inventory, vehicle, and building primitives remain rejected until
their exact Build 42 contracts are verified.

The client half of this same downloaded mod forwards only local player chat
that mentions Goblin through `OnClientCommand`; the server verifies the
sender's username and emits a bounded, coordinate-redacted chat event. This
is the input path for Qwen replies and does not create a player/account for
Goblin.
