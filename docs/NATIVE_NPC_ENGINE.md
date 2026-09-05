# Native NPC engine

GoblinSurvivor owns its NPC runtime. The implementation deliberately uses
the public/native Build 42 Lua surface instead of copying another mod's
source or requiring another Workshop item.

## Body creation

`NativeNpcAdapter.spawnIndividual()` uses this order:

1. Create a `SurvivorDesc` with `SurvivorFactory.CreateSurvivor()` (or the
   exposed friendly survivor type when available).
2. Call the native `createZombie(x, y, z, descriptor, 0, direction)` function.
3. If the descriptor path is unavailable, call native
   `addZombiesInOutfit(x, y, z, 1, "Survivor", 50)` and use its returned
   `IsoZombie`.
4. Immediately write the stable NPC id, native engine marker, friendly flag,
   role, protection flag, and task state to `getModData()`.
5. Clear target/aggro state and transmit the mod data before the body is
   exposed to the registry.

The adapter fails closed when no body is returned. It never chooses an
unrelated nearby population zombie. During the synchronous create callback,
the event handler may use a reservation containing the requested id and exact
spawn point; that reservation expires after fifteen seconds.

## Behavior ownership

The native adapter owns:

- friendly target clearing on every `OnZombieUpdate`;
- protected primary-body hooks (`setInvulnerable`, `setNoDamage`, and related
  methods when exposed);
- pathing through `pathToLocationF`, `pathToLocation`, and
  `pathToCharacter` when exposed by the current Build 42 body;
- follow, squad, guard, and return-to-base tasks stored in mod data;
- a bounded combat target that may only be a live non-player, non-friendly
  zombie; and
- chat through the body's native `addLineChatElement` primitive.

The Python/Qwen plane supplies intent, but it never receives exact body
coordinates and never controls a body directly. Lua resolves the semantic
target and enforces the safety boundary locally.

## Persistence and migration

Native marker fields are stored on the body and the stable identity/role/task
record is stored in server ModData. On a restart, the registry scans loaded
zombies for the matching native marker. A body carrying the old foreign
engine marker is not adopted; the bounded rebind scan removes that stale body
and lets the native engine create a replacement after its normal cooldown.

## Runtime validation

The Windows test harness must verify, in order:

- the mod loads without a missing-module or API error;
- Goblin spawns as a visible survivor body, not a hostile population zombie;
- Goblin does not attack or target a player while idle/following;
- `GoTo`, follow, guard, and return-to-base tasks move the body;
- an approved hostile-zombie target is pursued without making players valid
  targets;
- speech reaches the client; and
- save/restart rebinds the same identity, while death triggers bounded
  replacement.

The API names above are runtime-gated in Lua with protected calls. A missing
or changed API produces an explicit `sensor_only`/failed action result rather
than a fabricated success.
