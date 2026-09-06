# GoblinSurvivor next-agent handoff

Updated: 2026-09-06

## Objective

Finish the standalone Build 42.20.4 human-survivor engine, validate all
required behavior locally, push the development branch to GitHub, publish a
self-contained unlisted Workshop package only after local gates pass, and
install on production `.03` only after a separately guarded release review.

## Repository and environment

- Repository: `C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin`
- Branch: `checkpoint/pre-standalone-survivor-engine`
- Remote: `https://github.com/HorseTheUnicorn/zomboid-goblin.git`
- PZ install: `C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid`
- PZ data: `C:\Users\tomgr\Zomboid`
- Build: Project Zomboid 42.20.4
- Local profile: `goblin-local`
- Local endpoint: `127.0.0.1:16271` with UDP `16272`
- Production `.03`: untouched; do not use it for development validation.

Preserve the dirty worktree and unrelated user changes. Never use
`git reset --hard`, `git checkout --`, force push, or broad destructive file
operations.

## Architecture that must remain

The active body mode is `client_survivor`:

```text
PZ server Lua roster/tasks/bridge validation
    -> Storm ServerSurvivorAuthority
    -> HumanSurvivor Java actor and authoritative snapshot
    -> each connected PZ client creates a local HumanSurvivor visual

.76 Qwen/Python intent -> bounded command.npc_action -> server validation
PZ exact telemetry -> read-only tracker storage
```

`HumanSurvivor` extends `IsoLivingCharacter` and implements `IHumanVisual`.
It is neither an `IsoPlayer` nor an `IsoZombie`. The server owns identity,
generation, position, follow movement, jobs/tasks, firearm, ranged combat,
death, and bounded recreation. The client owns only local construction,
model/object registration, visual reconciliation, and animation ticks.

Do not reintroduce a zombie donor, fake player, native PZ client on `.76`,
Wine, or a dependency on an external NPC runtime. Normal population zombies
must remain normal zombies and may not be adopted as survivor bodies.

## Important files

- `storm/src/com/horsetheunicorn/goblinsurvivor/HumanSurvivor.java`
- `storm/src/com/horsetheunicorn/goblinsurvivor/ServerSurvivorAuthority.java`
- `storm/src/com/horsetheunicorn/goblinsurvivor/GoblinSurvivorStormMod.java`
- `storm/src/com/horsetheunicorn/goblinsurvivor/GridRoute.java`
- `mod/Contents/mods/GoblinSurvivor/42/media/lua/client/GoblinSurvivor/ClientSurvivorActor.lua`
- `mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/ClientSurvivorServer.lua`
- `mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/CommandLoop.lua`
- `mod/Contents/mods/GoblinSurvivor/42/media/lua/shared/GoblinSurvivor/ClientSurvivorProtocol.lua`
- `tools/Start-LocalPzClient.ps1`
- `tools/Stage-LocalPzClientCache.ps1`
- `tools/Build-GoblinStormMod.ps1`
- `tools/Sync-LocalPz.ps1`
- `tools/TestClientActorRetry.java`
- `tools/TestGridRoute.java`

The packaged jar at
`mod/Contents/mods/GoblinSurvivor/42/goblin-survivor-storm.jar` must be rebuilt
whenever Storm Java changes and then synchronized into the local package.

## Verified behavior

The latest local run established:

- server authority readiness and `body_mode=client_survivor`;
- seven real Java human bodies: Goblin, Sarah, Bob, Dave, Ellen, Mike, and
  June; logs identify `HumanSurvivor` and `isZombie=false`;
- client model/object registration, increasing render calls, and user-visible
  human characters;
- a clean isolated-client reconnect after a forced package refresh: the client
  completed `DoLuaChecksum` with `checksum=Success`, the server accepted the
  session, and all seven human actors were recreated. The isolated-cache
  staging helper now mirrors exact package contents and removes files deleted
  from the source package, preventing stale Lua/jar files from causing a
  future checksum mismatch;
- Goblin hair forced to `Spike`;
- all managed bodies equipped with `Base.AssaultRifle2` and a ready M14/.308
  firearm policy;
- Goblin follow movement in the tested area;
- one-shot/one-kill hostile-zombie fixture with no incoming hit; and
- Goblin death/recreation from generation 1 to generation 2 with the human
  body mode and firearm re-established.
- Hauler vehicle recovery was live-verified on the disposable `goblin-local`
  profile. The custom tile route correctly failed closed when the vehicle was
  behind an unreachable obstacle; the guarded Build 42
  `PathFindBehavior2.pathToVehicleAdjacent` fallback found a route, the
  headless server body advanced along collision-checked path points, and Dave
  entered and returned the car to the shared player/base anchor. The vehicle
  was not teleported and the dedicated-server path does not call
  `vehicle.updatePhysics()`.
- The live `.76` `goblin-zomboid-agent.service` and
  `goblin-zomboid-relay.service` now run the current repository Python control
  package. The existing Qwen service remains loopback-only at `127.0.0.1:8000`
  with model alias `qwen3-8b-q4km`; the existing memory database and production
  bridge mount were preserved, and the previous package has a recoverable
  rollback copy. A direct semantic-only probe through the active Qwen adapter
  now passes strict plan validation; the planner prompt explicitly documents
  the required fields for `SAY`, `FOLLOW_PLAYER`, `DEFEND_PLAYER`,
  `ASSIGN_JOB`, and `FORM_SQUAD`.
- Storm now owns the semantic admission/goal-submission step for the initial
  command slice. `RemoteCommandConsumer` checks the versioned command
  envelope, freshness, nested forbidden fields, logical IDs, and capability;
  `SurvivorCommandExecutor` deduplicates request IDs, resolves online player
  targets, and submits bounded HOLD/FOLLOW/REGROUP/home goals to the existing
  Java authority. Speech, squad/job, base, and area-specific resolution still
  delegate to the established Lua server adapter until each Java world-context
  path is verified.

The latest client cold load measured 278 seconds in the game-loading state.
The dated PZ log shows the main wait in vanilla `WorldStreamer.isBusy()` /
`IsoWorld.init` from 10:04:38 to 10:08:22 (about 224 seconds), with the
loading thread in `TIMED_WAITING` and filesystem queues empty. The server's
login queue completed at 10:08:24, after world loading finished. The actors
were created after that point, and the local profile has an empty Workshop
item list, so this delay is Build 42 map/world initialization rather than a
Workshop download or survivor-loop work. Keep a warm session alive while
iterating where possible.

## Current limitations and open gates

1. Melee combat and combat animation are not implemented or validated.
2. Bounded client snapshot interpolation is implemented; collision feel, doors,
   stairs, and cross-floor movement still need validation.
3. Goblin follow works in the tested area. A companion route can still report
   `UNREACHABLE` around a static obstacle (the latest captured log named
   `npc.mike`; an earlier handoff named June); inspect the exact grid, collision
   checks, and target selection rather than masking the result.
4. Builder and the other jobs need in-game behavior tests with measurable
   work effects. A bridge-only job probe using a fabricated grant was
   correctly rejected and must not be bypassed.
5. Guard, farmer, medic, scout, loot, and disassembly currently need
   behavior-level implementation/validation beyond status metadata. Hauler
   vehicle recovery has one successful live pathfinder/fallback run, but still
   needs broader obstacle, driving, persistence, and failure-case coverage.
6. Save/restart, cell unload/rebind, disconnect/reconnect, and duplicate-body
   cleanup need live tests.
7. A second-client probe used an isolated cache successfully but reused the
   first username and was rejected. Repeat with two distinct non-Steam
   usernames; cache isolation alone is not a multiplayer pass.
8. Companion/squad command behavior and the `.76` chat/Qwen round-trip remain
   open. The live `.76` package and direct semantic Qwen path are updated, but
   the isolated Windows client is currently still in the title/video path and
   has not completed a multiplayer handshake, so no new end-to-end command
   evidence has been recorded.
9. Workshop publication and `.03` installation are not complete and must not
   be attempted until the local matrix passes.

## Local commands

From the repository root:

```powershell
Set-Location 'C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin'
powershell -ExecutionPolicy Bypass -File .\tools\Sync-LocalPz.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzServer.ps1 -Storm
powershell -ExecutionPolicy Bypass -File .\tools\Start-LocalPzClient.ps1 -Storm -Visible -ConnectAddress '127.0.0.1:16271'
```

For an isolated parallel client, refresh the complete package before every
join after a source change. This also removes files left by an older package:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Stage-LocalPzClientCache.ps1 `
  -TargetPzDataRoot 'C:\Users\tomgr\Zomboid\goblin-local-client-7'
```

Use `-ManagedNpcCount 0` for a Goblin-only smoke test. Stop both processes
before synchronizing. Inspect:

```powershell
Get-Content -Raw 'C:\Users\tomgr\Zomboid\Lua\goblin-bridge\runtime\zomboid-state.json'
Get-Content -Raw 'C:\Users\tomgr\Zomboid\Lua\goblin-bridge\runtime\zomboid-exact-state.json'
$log = Get-ChildItem 'C:\Users\tomgr\Zomboid\Logs' -Filter '*DebugLog*.txt' | Sort-Object LastWriteTime -Descending | Select-Object -First 2
$log | Select-Object FullName,LastWriteTime,Length
```

In-game commands include `/gss status`, `/gss follow all`, `/gss hold all`,
`/gss attack goblin`, `/gss build Mike`, `/gss guard Bob`, `/gss squad all`,
and `/gss dismiss`. Treat a job status change as metadata until movement,
work counters, or world effects prove the job works.

## Validation already run

- Python contract suite: 108 tests passed.
- The live `.76` agent and relay remained active after switching to the current
  tested Python package; Qwen health returned `status=ok`.
- The active `.76` Qwen adapter accepted a semantic-only plan with four
  bounded commands; no exact coordinates were supplied to or returned by the
  adapter.
- Java route executable: 17 scenarios passed.
- Java Storm package built against the installed game.
- Client Kahlua retry harness passed.
- The isolated client passed a fresh post-refresh checksum join; the source,
  direct package, Workshop staging package, and isolated cache each contained
  the same 55-file package.
- `git diff --check` passed; only normal Windows line-ending warnings were
  reported.
- A source scan excluding `.git`, jars, logs, SQLite, and database files found
  no references to the retired external NPC framework.

Run the suite again after code changes:

```powershell
$env:PYTHONPATH='.'
python -m unittest discover -s tests -p 'test_*.py'
powershell -ExecutionPolicy Bypass -File .\tools\Build-GoblinStormMod.ps1
git diff --check
```

Do not claim a gameplay gate from static tests alone.

## Release order

1. Fix or explicitly bound the June/Mike companion route failure and validate
   jobs/melee; retain the verified hauler fallback while expanding its tests.
2. Run restart, unload/rebind, reconnect, duplicate prevention, and two-user
   multiplayer tests.
3. Run companion/squad and `.76` chat/Qwen round-trip tests.
4. Re-run package checks and the source scan; review the full diff.
5. Commit and push the development branch to the requested GitHub remote.
6. Publish the exact self-contained package as unlisted Workshop content and
   record its real published ID only after local gates pass.
7. Perform a separate guarded `.03` rollout with backup, no-player window,
   exact package, config review, restart, and post-restart log checks.

Never use a Workshop ID that has not actually been published, and never let a
local test failure trigger a production restart.
