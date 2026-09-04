# NPC architecture

`goblin.primary` is the sole stable Goblin identity. `NPCRegistry` binds that
identity to a Bandits-backed server zombie, scans for it after restarts, and
requests a replacement through the observed `BanditServer.Spawner.Individual`
API when an online player anchor exists. `GoblinNPC` exposes the narrow
profile/state surface used by telemetry and commands.

The execution path is:

```text
ValidatedIntent -> SafetyController -> SafeAction -> NpcBodyDriver
-> command.npc_action -> CommandLoop -> ActionExecutor -> BanditsAdapter
```

Protection is reapplied on every server tick. It records the protected NPC
profile, resets Bandits infection/needs fields, uses exposed engine hooks when
available, and relies on the persistent recovery loop when a hook is absent.
Unsupported combat, inventory, vehicle, or building primitives remain
rejected until their exact Build 42/Bandits contracts are verified.
