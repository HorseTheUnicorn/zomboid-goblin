# Friendly survivor runtime

The active friendly-survivor runtime is the standalone `HumanSurvivor` Java
actor plus the thin Lua snapshot layer. It is not a converted zombie and it
does not depend on another NPC package.

## Responsibilities

`ServerSurvivorAuthority.java` owns the server-side human object, identity,
position, task execution, firearm, hostile-zombie combat, protection, death,
and recreation. `ClientSurvivorServer.lua` owns the bounded roster and task
metadata. `ClientSurvivorActor.lua` creates and reconciles the local human
visual on each connected client.

The actor is an `IsoLivingCharacter` implementing `IHumanVisual`. It is not
an `IsoPlayer` and not an `IsoZombie`. Its vanilla needs and incomplete NPC
update loop remain disabled while the server authority supplies movement and
state.

## Friendly policy

The server validates every target. Friendly actors and players cannot be
selected as hostile combat targets. Normal population zombies remain outside
the managed roster. Goblin protection and the fixed `Spike` hair profile are
reapplied on recreation.

## Multiplayer behavior

The server publishes a sequence-numbered snapshot. Each client creates a
local `HumanSurvivor`, registers it in the cell object/model path, and
reconciles its position. Client construction retries per roster member and a
generation change removes the old visual before creating the replacement.

This is the current Build 42 multiplayer solution because the vanilla stream
does not provide a network packet for this custom human class. The local
single-client visual gate is passed. Two-client parity, reconnect, and unload
/rebind still need live validation.

## Limits

Ranged combat is implemented and tested with `Base.AssaultRifle2`. Melee,
smooth movement, full job effects, companion/squad behavior, and final
chat/Qwen round-trip remain open gates.
