# NPC architecture

`goblin.primary` is the sole stable Goblin identity. `NPCRegistry` binds that
identity to a server-created, networked Bandits2 survivor body marked with
this mod's own `getModData()` fields. It scans the loaded zombie population
after restarts and requests one replacement through Bandits2's public
`BanditServer.Spawner.Individual` entry point when an online player anchor
exists. `GoblinNPC` exposes the narrow profile/state surface used by
telemetry and commands.

The execution path is:

```text
ValidatedIntent -> SafetyController -> SafeAction -> NpcBodyDriver
-> command.npc_action -> CommandLoop -> ActionExecutor -> NpcAdapter
```

`NpcAdapter` selects `BanditsAdapter` only when the installed Bandits2 API is
complete. The Bandits adapter creates or repairs one private profile and clan,
sets `friendly=true`, uses the `Companion` program, clears both Bandits
hostility flags, and requires `loyal=true` and `permanent=true` before the
registry marks the body ready. Protection is reapplied on every server tick;
the body is also cleared of vanilla aggro when the exposed hooks exist. A
normal vanilla `IsoZombie` remains a sensor-only fallback because it has no
verified friendly relationship contract. The adapter deliberately does not
mark the body `useless`, because that population flag could make a persistent
NPC eligible for engine cleanup.
Unsupported combat, inventory, vehicle, or building primitives remain
rejected until their exact Build 42 contracts are verified.
