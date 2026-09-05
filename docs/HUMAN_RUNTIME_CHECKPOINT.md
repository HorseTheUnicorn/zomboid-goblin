# Human runtime checkpoint — 2026-09-05

Local Build 42.20.4 only. Production and publication gates remain closed.

## Verified

- The server-side Storm authority creates `HumanSurvivor` Java objects.
- The client creates all seven roster visuals from snapshots. The latest log
  identifies the class as
  `com.horsetheunicorn.goblinsurvivor.HumanSurvivor` and reports
  `isZombie=false`.
- The client actor is in the cell object list and model manager, has a model,
  sprite, legs, render permission, four worn items, and increasing render
  calls. The user confirmed the characters are visible in-game.
- Goblin's fixed appearance includes `hair=Spike`.
- Snapshot movement was observed in the prior walk test. Goblin changes
  position and the visual diagnostics switch between idle and walking poses.
- `Base.AssaultRifle2` is equipped and ready on the managed human bodies.
- The local hostile-zombie fixture produced one authoritative shot and one
  kill with zero incoming hits.
- A death/recreate fixture advanced Goblin from generation 1 to generation 2
  while retaining the human body mode and firearm policy.

## Rendering path

`ClientSurvivorActor.lua` creates the Java body, calls the Java model
registration bridge, places it in the current/moving square, and keeps the
object in `IsoCell.objectList`. The Java actor's preupdate/update/postupdate
methods are intentionally empty because the current authority supplies
position and task state; `tickVisual()` advances only the safe animation and
model path. Do not reintroduce the old vanilla NPC update loop or a zombie
fallback.

Useful live diagnostics are written by the client to the newest
`*DebugLog.txt`:

```text
created Java human survivor actor ... isZombie=false
render state: sprite=true legs=true activeModel=true model=true ...
inObjectList=true pendingRemoval=false ... hair=Spike ...
```

## Known live limitations

- Movement is snapshot-driven and may step/teleport between authoritative
  positions; smooth interpolation and collision feel are not complete.
- Goblin routes successfully in the tested area. June has a repeatable
  `UNREACHABLE` static route result and needs investigation.
- The server's ordinary zombie population has been observed. The current
  `ordinary_zombie_count=0` after disconnect reflects the current loaded area
  and is not a global population assertion.
- A second client has not yet been validated with a distinct username.
- Jobs, melee, unload/rebind, reconnect, companions, squads, and full chat
  round-trip remain open gates.

## Cold-load evidence

The 2026-09-05 client log reported `game loading took 278 seconds`. The
watchdog captured the loading thread waiting in `IsoWorld.init` during
`WorldStreamer.isBusy()` from 10:04:38 to 10:08:22 (about 224 seconds).
The filesystem work queues were empty during the stall. The server login
queue completed at 10:08:24, and the seven human actors were created only
after world loading completed, so the roster is not the primary cause of the
cold-start delay.

## Checks

- Python contract suite: 80 tests passed.
- Java route executable: 17 scenarios passed.
- Java Storm package built successfully against the installed game.
- `git diff --check` passed, with only normal Windows line-ending warnings.
- Source scan for the retired third-party NPC framework name is clean when
  generated binaries, logs, databases, and `.git` are excluded.
