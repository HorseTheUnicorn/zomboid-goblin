# Standalone human engine

The active engine is owned by GoblinSurvivor and is implemented by the
Build 42 Java class `HumanSurvivor`. The filename is retained for historical
documentation links; it does not describe a separate third-party runtime.

## Creation

`ServerSurvivorAuthority.java` creates a `HumanSurvivor` with a normal
`SurvivorDesc`, a stable actor id, a generation, a profile, and an exact
server position. The object extends `IsoLivingCharacter` and implements
`IHumanVisual`; `isZombie()` is false. The server does not claim an unrelated
nearby population entity.

## Server behavior

The Java authority owns:

- bounded roster creation and world rebind;
- same-floor route selection and movement intent;
- `FOLLOW`, hold, home, and job task state supplied by Lua;
- a real `Base.AssaultRifle2` firearm and unlimited-ammo policy;
- validated hostile-zombie targeting and ranged fire;
- protected Goblin health/death state and bounded recreation; and
- compact diagnostics used by Lua and the local test harness.

The current actor deliberately does not run the incomplete vanilla living
character update loop. The server advances authoritative state, while
`tickVisual()` on clients advances only animation/model/light work.

## Client behavior

`ClientSurvivorActor.lua` creates one local Java human for each snapshot,
registers it in the current/moving square and cell object list, and registers
its model with Build 42's model manager. It validates sprite/model/render
flags and retries a failed actor independently. A missing constructor never
falls back to a zombie.

## Persistence and failure mode

Identity and task metadata are persisted by the Lua server module. Body
generation distinguishes a recreated body from a stale visual. If a body is
missing or an API contract is unavailable, the system reports pending or
failed state and stays safe; it does not silently adopt a normal zombie.

## Current validation

The single-client visual gate, ranged combat fixture, and Goblin
death/recreation have passed locally. Melee, jobs with real work effects,
unload/rebind, reconnect, two distinct clients, and full chat/Qwen behavior
are still open.
