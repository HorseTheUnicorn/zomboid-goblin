# Local Bandits behavior reference

This document records observations from the locally installed Bandits B42
package. It is a reverse-engineering reference only; no Bandits source is
copied into GoblinSurvivor and no runtime module imports it.

## Installed reference

- Workshop item: `3268487204`
- Local package root:
  `C:\Program Files (x86)\Steam\steamapps\workshop\content\108600\3268487204\mods\Bandits\42.20`
- Mod metadata reports `id=Bandits2` and describes the package as compatible
  with B42.20+.
- The local package contains 132 Lua files, including shared `BanditBrain`,
  `BanditUtils`, `BanditPrograms`, `ZombiePrograms`, and `ZombieActions`.

## Useful behaviors observed

### Body humanization

The shared `Bandit.ApplyVisuals` routine operates on the donor's
`getHumanVisual()`, `getItemVisuals()`, and `getWornItems()` surfaces. It clears
inherited item/worn visuals and dirt/blood, removes attached items, configures
human body values, and then applies clothing in ordered body-location passes.

GoblinSurvivor will reproduce only the API calls that are verified against the
installed B42 runtime and will keep them behind capability checks. The
Bandits-specific visual tables and helpers are not dependencies.

### Brain and tasks

`BanditBrain` persists a serializable brain table in body ModData and treats
tasks as an ordered list. The package separates task selection from individual
`ZombieActions`; `ZAGoTo` requests `pathToLocationF` and updates movement
variables, while action modules provide start/working/complete behavior.

GoblinSurvivor follows the same useful separation with its own
`GSSurvivorBrain`, `GSSurvivorTasks`, and `GSSurvivorActions` modules. It does
not use the `ZombieActions` namespace, which avoids collisions and keeps the
high-level Qwen contract semantic.

### Caching and update cost

The local Bandits package has a `BanditZombie` cache and tiered update logic,
including weapon-range caches. This confirms that update frequency and cache
ownership matter, but the package also contains broad update paths that are
not suitable as a direct dependency for this project.

GoblinSurvivor uses a smaller spatial bucket cache and staggered refreshes:
one cell-level refresh feeds all managed survivors, and each survivor filters
nearby buckets by threat radius.

### Server spawning

`BanditServerSpawner` selects loaded grid squares from a player/cell context and
avoids spawning too close to players. GoblinSurvivor keeps the verified native
factory and reservation pipeline already in `NativeNpcAdapter`; a pending
reservation is consumed only by a matching donor near the planned square.

## Deliberately not copied

- `Bandit.*`, `BanditBrain`, `ZombiePrograms`, and `ZombieActions` namespaces.
- Bandits global patches, compatibility modules, AI programs, audio tables,
  or item databases.
- Bandits workshop metadata or Workshop item dependencies.

The final release test must run with Workshop item `3268487204` disabled.
