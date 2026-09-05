# Standalone B42 survivor-engine status

Updated: 2026-09-05

## Scope

This checkpoint tracks the standalone Build 42 human-survivor engine. The
development branch is `checkpoint/pre-standalone-survivor-engine`; the
production `.03` server, its save, and its package have not been changed by
the local validation work.

The authoritative checkout is:

```text
C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin
```

The visible OneDrive `GoblinSurvivor` folder is not this checkout.

## Current architecture

- `HumanSurvivor.java` is a real Build 42 human Java actor. It extends
  `IsoLivingCharacter`, implements `IHumanVisual`, and is neither an
  `IsoPlayer` nor an `IsoZombie`.
- `ServerSurvivorAuthority.java` owns authoritative actor identity, position,
  generation, firearm state, follow movement, hostile-zombie combat, death,
  and bounded recreation on the server.
- `ClientSurvivorActor.lua` creates a local human visual actor from the
  server snapshot. It registers the actor in the FBO object/model path and
  never uses a zombie as a visual fallback.
- `ClientSurvivorServer.lua` owns the roster, tasks, jobs, persistence,
  snapshots, in-game `/gss` commands, and bridge-facing validation.
- Python and Qwen remain an intent/telemetry plane. They do not receive an
  unrestricted body-control or exact-coordinate interface.

The current body mode is `client_survivor`: the server owns the logical
actor and each connected PZ client renders its own local human actor from the
bounded snapshot. This is necessary because the installed multiplayer build
does not provide a vanilla network packet for this custom human class.

## Verified decisions

- No external NPC runtime is required or loaded.
- `.76` must not run a native PZ/Steam gameplay client. Windows PZ is only the
  local development harness.
- No fake `IsoPlayer` and no zombie fallback are acceptable final bodies.
- Goblin and the managed companions use `Base.AssaultRifle2`, an M14 clip,
  `.308` ammunition, the bounded unlimited-ammo policy, and the server-side
  protection policy.
- Goblin's hair is forced to `Spike` after visual/profile setup.
- Normal population zombies remain ordinary zombies. The local combat fixture
  creates only a hostile test zombie and is guarded by development settings
  plus an exact local-test token.

## Verified local evidence

On 2026-09-05, local Build 42.20.4 produced:

- server authority ready and `body_mode=client_survivor`;
- Goblin, Sarah, Bob, Dave, Ellen, Mike, and June created as
  `com.horsetheunicorn.goblinsurvivor.HumanSurvivor` with `isZombie=false`;
- client render diagnostics with `sprite=true`, `legs=true`,
  `activeModel=true`, `model=true`, `doRender=true`, `inMovingList=true`,
  `inObjectList=true`, `pendingRemoval=false`, and increasing render calls;
- `hair=Spike`, `firearm=Base.AssaultRifle2`, and a ready firearm;
- user confirmation that the characters are visible in the game;
- deterministic ranged combat: one shot, one hostile zombie killed, and no
  incoming hits in the fixture run;
- death/recreation: Goblin generation advanced from 1 to 2 and the recreated
  body re-equipped the rifle and returned to follow behavior;
- ordinary population zombies observed during the live run. A zero count
  after the client disconnected is not evidence that population spawning is
  disabled.

The latest measured cold client load was 278 seconds. The client log shows
the largest interval—about 224 seconds—inside vanilla
`WorldStreamer.isBusy()` / `IsoWorld.init`, with the loading thread waiting
and filesystem queues empty. `WorkshopItems=` is empty in the disposable
profile, so that delay was not a Workshop download. See `LOCAL_TESTING.md` for
the warm-session workflow.

## Gates still open

1. Ranged combat is verified; melee combat and combat animation are not.
2. Goblin follow works in the tested area, but June repeatedly reports an
   `UNREACHABLE` route around a static obstacle and needs a real-world route
   fix or a documented supported limitation.
3. Jobs, especially Builder, need an in-game command test with a valid server
   grant and a measurable work result. A bridge-only fake job request was
   correctly rejected by authority validation.
4. Guard, hauler, farmer, medic, scout, loot, and disassembly behavior need
   behavior-level validation rather than status-only assertions.
5. Save/restart, cell unload/rebind, disconnect/reconnect, and duplicate-body
   cleanup need live tests.
6. A second client has not passed: an isolated process reached the server but
   reused the first client's username and was rejected. It must be repeated
   with a distinct user identity.
7. `.76` chat/Qwen round-trip, companion/squad commands, and the final
   integration path remain to be tested end-to-end.
8. GitHub publication is authorized but must include the final intended
   checkpoint. Workshop publication and `.03` installation remain closed
   until the local gates above pass.

No production restart or production configuration change is authorized by
this checkpoint.
