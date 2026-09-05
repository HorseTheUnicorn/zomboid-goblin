# Bandits API notes

## Current decision

The current `GoblinSurvivor` release does **not** use Bandits or any other
Workshop NPC framework. The project originally planned to wrap Bandits, but
the implementation was changed to a self-contained native Build 42 engine at
the operator's direction. `NativeNpcAdapter.lua` is now the only body adapter
and `NpcAdapter.lua` is the only stable facade above it.

This file is retained as the migration record required by the original
architecture plan. It prevents a future maintainer from treating an old
Bandits package or guessed Bandits function name as a hidden dependency.

## Removed dependency surface

The current package has no Bandits Workshop ID, no `require("Bandits/..." )`
call, and no Bandits-specific entity lookup, brain, task, persistence, or
network synchronization code. A server configuration must therefore contain
only `GoblinSurvivor` for this mod; it must not add a Bandits item merely to
make GoblinSurvivor start.

## Native replacement contract

The native adapter currently owns these verified-at-runtime operations:

- body creation through `createZombie` with a survivor descriptor, with the
  bounded `addZombiesInOutfit` fallback;
- stable ownership and identity through `getModData()` markers;
- friendly/protected state and target clearing;
- movement through the exposed `pathToLocationF`, `pathToLocation`, and
  `pathToCharacter` methods;
- semantic speech through the body's `addLineChatElement` method when exposed;
- bounded combat against a live hostile zombie only; and
- persistence/rebind and delayed replacement through `NPCRegistry`.

Every Java/Lua call is runtime-gated and wrapped so a changed Build 42 surface
fails closed to `sensor_only` or a rejected action. The adapter must never
adopt a normal population zombie merely because it is nearby.

## If Bandits is reconsidered later

Do not add calls based on memory or a public description. First inspect the
exact Workshop package and version installed on `.03`, record its actual Lua
functions and hooks here, and implement a separate adapter behind the existing
facade. Keep the native adapter available as the safe fallback until an
in-world integration test proves the alternative body contract.
