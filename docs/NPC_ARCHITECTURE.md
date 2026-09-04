# NPC architecture

`goblin.primary` is the sole stable Goblin identity. `NPCRegistry` binds that
identity to a server-created, networked vanilla `IsoZombie` body marked with
this mod's own `getModData()` fields. It scans the loaded zombie population
after restarts and requests a replacement through the documented
`addZombiesInOutfit` server Lua function when an online player anchor exists.
`GoblinNPC` exposes the narrow profile/state surface used by telemetry and
commands.

The execution path is:

```text
ValidatedIntent -> SafetyController -> SafeAction -> NpcBodyDriver
-> command.npc_action -> CommandLoop -> ActionExecutor -> VanillaNpcAdapter
```

Protection is reapplied on every server tick. It records the protected NPC
profile, disables body damage and clears vanilla aggro when the exposed hooks
exist, and relies on the persistent recovery loop when a hook is absent. The
adapter deliberately does not mark the body `useless`, because that population
flag could make a persistent NPC eligible for engine cleanup.
Unsupported combat, inventory, vehicle, or building primitives remain
rejected until their exact Build 42 contracts are verified.
