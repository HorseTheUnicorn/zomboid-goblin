# Abilities V2 evidence ledger

## Current checkpoint — 2026-09-26

- Native toolkit sample: all 29 configured reusable types had one reserved
  inventory copy, with unchanged native item identities after 30044 ms.
  Read-only probe did not provision or mutate anything. See
  MILESTONE3_TOOLKIT_CHECK.md for hashes and remaining conservation/repair/
  persistence gates. Two probe tests and 30 job/runtime-identifier tests pass.
- Missing-key CustomLock test on 4bb2e8a: front door stayed locked with no
  matching key; back-door approach timed out, then alternate window opening
  and physical interior arrival completed. Fixture restoration succeeded.
  Two clients disagreed on temporary lock flags, and window replication was
  not observed, so this is server-side access/fallback evidence only. Earlier
  no-key porch opening was permitted by installed vanilla ISLockDoor, not a
  proven lock bypass. No gameplay changes made. See the existing-building
  evidence note for exact source hashes, positions and remaining gaps.
- Live keyed-door follow-up on fe712ab: Goblin approached a selected real door
  with one matching Base.Key1, cleared both native lock flags, opened it and
  reached the interior. Both no-Storm clients observed locked/closed ->
  unlocked/open. The real key remained in inventory, then exact fixture-key
  removal and original door-state restoration succeeded. All five gameplay
  packages matched. Probe files/flags were removed. This extends ordinary-door
  evidence, not missing-key denial, route ranking, padlock/breach or save/reload
  proof; see MILESTONE3_EXISTING_BUILDING_CHECK.md for source-bound results.
- Keyed-door fault injection reproduced a no-op native unlock setter reaching
  the silent toggle while still locked. Native lock/key flags now require
  successful false readback for every grouped panel before opening. A second
  failing case reproduced retry skipping a locked sibling after the selected
  panel partially unlocked; retries now inspect the group. Coverage includes
  no-op/throwing setters, unreadable post-state, normal success and grouped
  retries. All 125 focused access/work/house checks pass; full suite 537 tests
  succeeds with two existing expected failures; catalog consistency passes.
  This is automated failure-path hardening only, not live keyed-door proof.
  The running local packages were not replaced/restarted for this edit; the
  preceding ordinary-door replication evidence retains its original hashes.
- Closed-door follow-up: the local normal GAIN_ACCESS path reopened a selected
  ordinary door and reached its interior side. A subsequent two-client test
  recorded real door:isOpen transitions true -> false -> true independently
  in both no-Storm clients, with server opening/crossing and successful fixture
  restoration. All 170 gameplay files matched; probes/flags were removed.
  This verifies ordinary-door state replication, not locked/breach/gate or
  save/reload acceptance. Full timestamps, hashes and limits are recorded in
  MILESTONE3_EXISTING_BUILDING_CHECK.md.
- Existing-building native check: a disposable, non-breach probe submitted
  GAIN_ACCESS through Brain/Jobs with no geometry or position overrides. The
  selector chose a real open doorway; server positions moved from outside to
  its intended interior side and returned COMPLETE, with the reply visible in
  the normal client. The observer cleaned up and its staged file/flag were
  removed. This is one-client backend evidence, not chat, locked-door, smooth
  animation, replication or save/reload acceptance. See
  MILESTONE3_EXISTING_BUILDING_CHECK.md for hashes, trace and limits.
- Access target revalidation: two failing regressions demonstrated that a cached
  open-route state bypassed later safehouse denial and an already-smashed window
  returned success before breach policy. Door/window routes now re-resolve the
  target on every update, including while crossing. Safehouse checks precede
  already-open success, and breach policy precedes already-smashed success.
  A permitted reclosed door reopens once; subsequent ticks do not toggle it,
  and removal of the selected target terminates the job. All 35 access tests
  and the full 534-test suite pass (two existing expected failures). Catalog
  consistency passes. These are regression tests; live replication is pending.
- Access restoration follow-up: reproduced a completed yard doorway crossing
  being reversed after the capability's runtime table was lost. The original
  side now persists in the primitive task payload; restoring before crossing
  continues toward the same side, and restoring after crossing reports completion
  without another movement or door toggle. Alternate routes clear this origin,
  and invalid saved sides fail with TARGET_CHANGED. All 32 access tests pass.
  This is simulated runtime restoration, not a claim of actual server save/reload
  or multiplayer acceptance.
- Reproduced an access-direction bug: a Goblin already on the inside edge of
  a building was ordered outside, and that outward crossing counted as success.
  Scoped room/building routes now persist the intended interior side, retain it
  across alternate routes, approach that side and require it for completion.
  Existing yard traversal remains bidirectional. This affects GAIN_ACCESS only;
  accepted FOLLOW behavior is unchanged.
- The regression failed before the fix. All 31 access tests now pass, including
  already-inside, outside-to-inside, room orientation, alternate-route and invalid
  destination cases. The full suite ran 530 tests successfully with two existing
  expected failures. The 64-record catalog consistency check passes with refreshed
  implementation hashes. These are automated checks, not new engine acceptance.
- Before this source edit, disposable server PID33060 loaded nine capabilities
  with server-side Storm. Ordinary clients m3path_61 and m3witness_54 entered
  the world and each spawned one Goblin with Goblin_Community_Human appearance.
  The second client process ended and disconnected at 10:35:49 before the access
  command produced an observed result. No two-client access pass is claimed.
- Milestone 2 remains closed for the framework scope described in
  MILESTONE2_CLOSEOUT.md. Its older live acceptance manifest still correctly
  fails the current-source hash check; do not relabel that historical evidence.
  Milestone 3 and the wider V2 goal remain incomplete. See V2_STATUS.md for the
  remaining implementation and verification work.

## Current checkpoint — 2026-09-24

- M3 route retest: disposable server PID50848 and ordinary no-Storm client
  PID44340. Brain accepted GAIN_ACCESS for a test padlocked `IsoThumpable` at
  edge 10881,9989. Native padlock removal succeeded (key consumed, one matching
  padlock returned) and the door opened/unlocked. The actor did not register a
  physical crossing; the task ended `NO_PATH`, and cleanup=true restored FOLLOW
  and removed the test objects. This was a freestanding gate in an open yard,
  without a wall/frame around it; native pathfinding could route around the
  artificial obstruction. Treat this result as **inconclusive for production
  access traversal**—it is neither a route pass nor evidence of a production
  regression. Next physical test must use a real wall-framed doorway or an
  enclosed fixture, then verify the opened state from a second client. Earlier
  probe logging was also corrected to use the installed `IsoThumpable:IsOpen`
  method and isolate observations with `pcall`. Production code was not
  changed in response to the invalid fixture.
- Milestone 3 native padlock probe PASSED on disposable goblin-local, server
  PID10604 with no-Storm clients rejoinfang_74 PID6088 and trailfang_74 PID41668.
  At st=514940500 the actual managed actor had test key ID722718787. The native
  adapter consumed that key, returned exactly one Base.Padlock with original
  lock key ID214660123/key-count one, cleared padlocked and set gate key ID=-1.
  Repeated removal was refused; world/item fixture cleanup logged true at
  st=514940510. Preserved trace:
  C:\Users\tomgr\Zomboid\Logs\m3-padlock-native-20260924.stdout.log.
  GoblinAccess, GoblinPadlocks and GoblinTools source hashes matched both staged
  packages. Removed staged probe and opt-in flag; reusable source remains only
  in tools/probes. Latest full suite: 525 passed, 2 expected failures and 1,274
  subtests. This proves native managed-actor inventory/world mutation, not
  movement, second-client visual replication, or persistence; Milestone 3 is
  not yet complete.
- Milestone 3 matching-key padlock candidate implemented in GoblinPadlocks.lua.
  Base.Padlock resolves enabled/nonobsolete in the loaded catalog, from
  media/scripts/generated/items/key.txt. Installed ISPadlockAction removal and
  Java key/setter signatures were inspected. Ordinary access may now remove
  a single gate padlock only with an actual contained matching key; it returns
  the lock with the same key ID and one key, consumes that key, clears lock/key
  ID and calls native sync. Safehouse/server/managed-actor policy stays enforced.
  Native failures trigger compensation and a runtime target latch to prevent
  repeated partial transfers. No player-container packets are sent for Goblin.
  Combined/double-panel padlocks and combination-code removal stay unsupported.
  Five new tests cover transfer identity/counts, replay, missing key, client
  authority, compensation and safehouse denial. No actual gate movement,
  replication or save/reload proof is claimed yet. This supersedes the prior
  note that all padlock removal was unimplemented.
- Milestone 3 special-lock audit: reproduced ordinary unlocking silently
  clearing isLockedByPadlock/getLockedByCode without the installed native
  item transfers or code authorization. Removed those setters from ordinary
  unlocking; special locks are rejected at selection and every grouped door
  panel is preflighted before any mutation. All 117 targeted access/work/house
  tests pass, including no mutation for keyed-padlock, combination-lock and
  mixed-panel cases. This corrects a bypass, not implementation of padlock
  removal. Remaining adapter requirements from installed ISPadlockAction are:
  real matching key, Base.Padlock with same key ID and one key count, consume
  that exact key, clear lock/key ID, synchronize world object; managed inventory
  must not use the unsupported player-container packet path. Combination locks
  require an explicitly supplied matching code and return Base.CombinationPadlock
  per ISPadlockByCodeAction. Neither may infer authorization from being indoors,
  from a normal door key, or from Qwen's guessed data. Local-only source change;
  no new physical or multiplayer acceptance is claimed.
- Milestone 3 native door-policy parity: installed ISLockDoor:isValid explicitly
  refuses keyless inside unlocking when door modData.CustomLock is truthy.
  Goblin's inside-edge adapter omitted that condition. A regression reproduced
  the bypass; the adapter now retains the native restriction while allowing a
  real matching key and preserving ordinary inside-to-outside unlocking.
  All 116 targeted work/access/house tests pass. This change is not yet staged
  or live-multiplayer-tested; source inventory hashes describe implementation,
  not new physical acceptance. Padlock removal uses a separate installed native
  action with item/key transfers and must not be inferred from ordinary door
  unlocking. Milestone 3 remains open for the remaining compatibility and live
  evidence checks.
- Milestone 3 toolkit review found that fuel removal was unchecked and the
  previous idempotence test had no drainable fixture. Added a failing regression
  for throwing/ineffective drainable setters and ineffective fluid mutation.
  Provisioning now verifies zero with installed getCurrentUsesFloat/getAmount
  and removes a newly created tool on failure before marking it reserved.
  Existing reserved tools retain real fuel acquired later. Installed Java
  signatures and FluidContainer.adjustAmount bytecode were inspected directly.
  This is a local source/test correction, not a new live ability claim; no
  restart, deployment, or publication was performed. Access and tool inventory
  retain their existing explicit unverified-native-action limitations.
- Milestone 2 framework is closed following the user's acceptance of earlier
  local tests and request to complete its remaining work. See
  [Milestone 2 closeout](MILESTONE2_CLOSEOUT.md) for the requirement mapping,
  terminal-replay fix, actual craft evidence and explicit per-ability limits.
  This supersedes pending-framework wording in the chronological entries below.
- The user subsequently confirmed "everything is working for goblin following"
  and asked to move on. Stop repeating follow acceptance routes; preserve that
  baseline. Formal historical no-teleport/door/stair evidence limitations remain
  recorded rather than being converted into invented current-build proof.
- Milestone 2 follow-up: reproduced repeated handler execution after terminal
  completion/error in a focused regression. The capability runtime now latches
  its canonical terminal result until Jobs.clear/cancel starts a new job.
  This prevents duplicate ticks from replaying a potentially partial physical
  operation. Success, exception, malformed result, copy isolation and explicit
  restart are covered. All 78 focused capability/job/base/logistics tests pass.
  This is worktree-only and not yet loaded into the running local test server.
- Subsequent M2 test staging: full suite 520 tests passes (two expected
  failures). Restarted only disposable goblin-local with the registry latch.
  Server PID17896; ordinary clients rejoinfang_74 PID58732 and trailfang_74
  PID58128, no client Storm. An explicit-owner/profile-gated temporary probe
  from tools/probes/Milestone2CraftProbe.lua is staged server-side, with the
  opt-in flag. It seeds one real log only if test material counts start at
  zero, routes SawLogs through Brain/Jobs, and observes terminal repeat safety.
  The probe must be removed from the staged server and its flag removed after
  the test. It is outside the release mod tree in the repository. Live result
  is pending world entry; no physical success is claimed by the staging step.
- M2 live craft/result checkpoint completed on 2026-09-24: rejoinfang_74
  entered with Rattlefang Soupthief. Probe observed initial logs=0/planks=0,
  seeded Base.Log ID1372441715 at st=513484854, and Brain accepted SawLogs x1.
  Native WORKING results retained log=1/planks=0, then COMPLETE at
  st=513509449 had log=0/planks=3. A duplicate Cap.update returned COMPLETE
  with inventory_unchanged=true before Brain delivered the outputs. The
  ordinary no-Storm client visibly displayed Plank (3) in Ground inventory at
  the owner's feet. Source log preserved at
  `C:\Users\tomgr\Zomboid\Logs\m2-craft-terminal-20260924.stdout.log`.
  Registry SHA256: 26f6b7aef7eeb83152120bb4a2b08663f450790aa2292116bed651e11163c11b.
  Jobs SHA256: be06dd44d51baab8d4e1b4a617a6fe64f85c40f6f6d8a87d42be9b33876844c0.
  Craft SHA256: 8640ee2f58a0ebfadce58e6ef1bff4c762b22e79f39b486b2da4431e78d4e4cd.
  Probe SHA256: cacc6e3e04b5b6b199ebf2318e67d78d444c0516b48504d44db489a638626272.
  These three Lua modules matched both staged packages. Removed only the
  temporary staged probe and opt-in flag after its wrapper restored Jobs.update;
  reusable probe source stays outside the release mod. Both players connected,
  but the distant second client did not inspect the outputs and reload was not
  tested. This closes the narrow craft/terminal-repeat smoke check, not all M2
  regression, multiplayer replication, or persistence requirements.

- The user accepted the local movement/freezing correction: "perfect, fixed".
  The final change makes the Goblin-only turnalerted fallback non-looping,
  matching the installed native completion transition. The attempted direct
  ActionContext Lua recovery was removed after the live runtime rejected it.
- Preserve this accepted movement baseline. This acceptance is not a claim
  that all V2 abilities or all current-build multiplayer gates are finished.
- M1 evidence now binds 17 source files, including the guard and turnalerted
  XML, plus the server JAR. Historical source-bound passes remain historical.
- Next: Milestone 3 tools/access gap review, preserving the user-accepted follow
  baseline. Production and published artifacts remain untouched. Dated entries
  below retain historical status, not current instructions to repeat testing.

## Gate: Milestone 0 catalog refreshed for the 2026-09-23 `.03` snapshot

Section 31's non-mutating loaded-registry catalog and conservative compatibility
inventory have been refreshed from an exact disposable copy of `.03`'s current
installed scripts and configured Workshop content. The source archive SHA-256
was `cbc1f755858f7c5f4ed3d2c29e498c5f8500d3b87179f25ef31e08f481223471`;
the local copy matched, and the temporary archive was removed from `.03`.
The installed game JAR still hashes to
`80e405a4bfc42f6072e75b3735f458a6514143da011d3226007ded305a442f44`.
The isolated Build 42.20.4/Storm server exported 5,397 loaded items and 1,118
loaded recipes with `CONTENT_VERIFIED` selected-content fingerprint
`c7fefb1cff630f72b8277acefdab7f796b55b62ed614edb9650e8ab854385b67`.
Independent reconciliation matched all 68 configured mods and both vanilla
scripts/Lua trees; only the explicit candidate Goblin Java helper differs.
The configured Goblin Workshop item is `3797199625`; an installed but
unconfigured older item `3794624741` also contains a `GoblinSurvivor` folder
and is excluded by the corrected staging/reconciliation tools. The new and old
catalogs have identical item and recipe ID sets, though the installed script
checksum and selected-content fingerprint changed. Strict catalog and 64-record
capability-inventory checks pass. This is a dated snapshot, not a perpetual
assertion about future Workshop updates. The `.03` game service was inactive
throughout; it was not started, and no installed game or mod files were changed.

Milestone 0 is catalog/compatibility inventory only. No new physical ability,
multiplayer replication, or managed-IsoZombie compatibility is inferred from
the loaded registry.

2026-09-23 handoff: the user accepted the current local follow behavior as-is,
including the occasional stall that clears when the player returns close to
Goblin. No further follow-path changes are planned for this acceptance. The
Milestone 2 result boundary now canonicalizes handler results before storing
or returning them, so extra engine references and caller mutations cannot
enter the persistent snapshot. Targeted capability/job tests and the Section
31 inventory check pass. Requirement metadata, prepared payloads and runtime
snapshots now return independent primitive copies; a dynamic requirement
callback failure returns no requirement instead of escaping the registry.
The full local suite reports 496 tests passing with two expected failures.
This framework hardening is unit-tested only; the
historical Milestone 2 multiplayer record remains source-stale and is not
current live acceptance.

2026-09-23 Milestone 2 retest attempt: a disposable `goblin-local` server with
server-side Storm loaded the current nine-handler registry, and two ordinary
no-Storm clients connected. Both clients reached the loaded-world screen but
had not entered play; no managed Goblin spawned, so the one-time physical
SawLogs probe never ran. The Windows game-window helper failed to capture its
target after refresh, so no input was issued. The local server and both clients
were stopped, and the probe was removed from every staged package. This is a
failed/incomplete acceptance attempt, not evidence of crafting or replication.
The same window-capture error recurred with only one game client open. That
client connected but did not enter play. The single-client retry was stopped
as well; no local game process was left running. The user is not currently
available to click into the world, so the live gate remains pending.

2026-09-23 current-source multiplayer follow-up: after a fresh desktop-control
session, `rejoinfang_74` and `trailfang_74` entered a disposable local Build
42.20.4 world using ordinary no-Storm clients. The Storm server spawned exactly
one named, visually applied Goblin for each player. A temporary server-only
probe observed all nine registered capability names, seeded exactly one real
`Base.Log` into `rejoinfang_74`'s Goblin, and called `Brain.setTask` for one
`SawLogs` batch. The server recorded `WORKING` then `COMPLETE`; its inventory
changed from one seeded log to zero. Goblin immediately delivered its cargo,
so the delayed probe found zero planks still carried, but the first ordinary
client visibly showed `Plank (3)` in the ground inventory at the player's
feet and displayed the craft/delivery messages. No capability/job error
appeared around this operation. Sixteen relevant Lua files and the server JAR
matched the current worktree in both staged packages by SHA-256. The second
client was at another location and did **not** verify those planks' replication.
The local pair was stopped and the one-time probe removed. This is strong
current-source evidence for the Milestone 2 registry and representative native
craft route, but it does not close the separate per-ability multiplayer and
persistence gates or the nine current-source Milestone 1 live gates.
The schema-2 Milestone 1 verifier now also binds the exact server JAR that
provides native movement/authority support; a missing or changed JAR rejects
acceptance. Eight focused verifier/trace tests pass. No new navigation behavior
or live-route claim was introduced by this proof-boundary change.

Milestone 1 implementation is in a unit-tested candidate state: native
character-follow, stable nearby slots, radius-2 work staging, bounded stuck
recovery, temporary route blacklists, exact Build 42 path-next field handling,
and navigation telemetry are implemented. Immediate native rejection of a work
approach now retires that candidate and tries another; boundary tests cover both
alternate selection and exhaustion after 25 candidates. This is not live engine
acceptance. A full local multiplayer run passed
on 2026-09-20 for its captured source, but all six source-bound files have since
changed. Milestone 2's historical acceptance likewise differs from five of its
eight bound files. Neither historical pass certifies the current worktree;
Milestone 1 is **not currently complete** until the changed build is revalidated.
Blocked navigation now emits a single `NAV_BLOCKED` transition log with task,
goal, retry, authority, progress age and last-movement context; telemetry
preserves the original rejection reason and last successful movement while a
route remains blacklisted. These diagnostics have boundary tests only.
The last full repository suite run on 2026-09-23 had 468 tests and passed with
two expected failures; the subsequent targeted navigation/work set has 144
passing tests. Historical Milestone 1 and Milestone 2 records now have separate
structure checks; their strict current-source acceptance commands reject both
records as stale. A fresh `goblin-local` server with server-side Storm and one
ordinary no-Storm client loaded the current worktree on 2026-09-23. SHA-256
comparison matched all six Milestone 1 source-bound files between worktree and
local package. Server/client logs show one `fencefang_73` Goblin spawned and
its visual applied. A ten-second exact-state sample showed one tile of Goblin
movement while the player was stationary. This is a one-client smoke check,
not the required two-client physical/authority acceptance.
FOLLOW now retains its active movement record while the owner is offline or
nearby squares are temporarily unavailable, and after reaching a stable slot;
these lifecycle cases have Lua boundary tests but no new live acceptance.
An installed method,
parsed definition, accepted command or
mock test is still not proof of physical execution or multiplayer replication.
Every capability remains `complete: false` until its own movement, material,
world-state, second-client and persistence acceptance evidence is recorded.
The current worktree also rejects unknown post-removal inventory state during
material reservation and holds exact item references for an in-process refund
retry. This is unit-tested only; restart/crash recovery and multiplayer material
accounting remain unverified.

2026-09-23 local Milestone 1 follow-up: the current candidate loaded on a
server with Storm and two ordinary no-Storm clients, and exactly one managed
Goblin spawned for each of `fencefang_73` and `bramblefang_92`. The server
observed `fencefang_73` switch from autonomous LOOT to FOLLOW when its owner
moved; exact-state samples then showed client-owned Goblin movement. The first
run also showed a real blocked native route: a client logged
`NAV_BLOCKED task=FOLLOW ... no progress after native repath` while the actor
remained behind. The server previously regarded delegated path acceptance as
progress; `GoblinWorld.approach` now checks observed actor displacement and
blacklists a stalled work approach after the native repath window. A boundary
  test covers alternate selection after that stall, and 145 focused
navigation/work/chat/acceptance-structure tests pass. This is not a fresh
nine-gate Milestone 1 live acceptance. Two local client window activations by
desktop automation each caused a native `glfw.dll` crash, so further game-window
automation was abandoned. A temporary local RCON test port used for player
staging was closed, its password cleared, and the probe removed. No production,
GitHub, or Workshop files were changed. Milestone 1 remains incomplete pending
fresh closed-door, radius-2, no-progress recovery, handoff, furniture, stair,
building-follow, and managed-door evidence on the current source.

The next exact-state trace exposed a separate follow/idle handoff: while
`fencefang_73` was stationary, his Goblin was roughly 80 tiles away and had
already changed from FOLLOW to autonomous LOOT. The idle decision now waits
until an online owner's Goblin has reached the same floor and is within the
nearby follow band. A Lua boundary test covers the far-then-caught-up sequence;
the focused set of 145 tests passes. The disposable local server and both
no-Storm clients were restarted with this change on 2026-09-23. Both clients
connected, then entered the world after a longer load; the server recorded
one Goblin per player and `native_owner_player` matched each owner. A
current-source trace showed `bramblefang_92` moving about six tiles while his
Goblin closed an 11-tile gap to about three tiles. Later, after more than 30
seconds of owner idle time, that Goblin entered autonomous LOOT from nearby
and moved away. This is partial follow/idle evidence, not the nine-gate
Milestone 1 acceptance run: no controlled closed-door, stairs, building-run,
furniture-detour, or simulation-owner handoff has been recorded on this build.
An initial desktop capture presented an occluding Firefox page for a selected
PZ window. Later foreground capture showed the live game, and keyboard/chat
input was attempted without another crash, but it did not yield reliable
controlled avatar movement or an observable submitted chat order. Those
inputs are not acceptance evidence. Leave the local pair running for the
remaining physical checks; Milestone 1 remains incomplete.

A subsequent attempt to foreground a local PZ window on 2026-09-23 caused
the isolated `bramblefang_92` client to exit with a native `glfw.dll` access
violation in `Display.processMessages`. The dedicated server and
`fencefang_73` client stayed up; the isolated client was relaunched without
Storm. No further desktop injection is planned for this acceptance run.
The restarted client rejoined with its personal Goblin, returning the topology
to two ordinary clients and two companions. The historical nine-gate record
remains readable as schema 1, but strict current-source acceptance now requires
a fresh schema-2 record binding 14 relevant follow, access, authority, work,
and telemetry modules (including `GoblinAutonomy.lua` and
`GoblinMovement.lua`). The checker and its four focused tests pass; the
current acceptance command correctly rejects the legacy record.
The inventory's FOLLOW completion review now delegates to that same strict
schema-2 checker rather than independently accepting the six-file historical
manifest. Five source-audit hashes for UNLOCK_VEHICLE, FOLLOW, MOVE_TO, and
EQUIP were refreshed after reviewing the corresponding world/locomotion/body
diffs; none of those records was marked physically complete by the hash update.

2026-09-23 current-source handoff probe: the disposable local server loaded
all 14 schema-2 bound modules with hashes matching this worktree. A temporary
random-password RCON channel moved only the two test players. Before staging,
`goblin.primary.fencefang_73` was beside its owner near `(10728,10576,0)`
under `fencefang_73`'s native simulation authority. With `bramblefang_92` at
`(10727.02,10575.95,0)` and fencefang at `(10747.96,10576.20,0)`, the same
Goblin was observed at `(10726.79,10575.32,0)` with
`native_owner_player=bramblefang_92`. Later it was observed at
`(10754.40,10577.57,0)` near fencefang, with native authority returned to
`fencefang_73`. The server logged no `FOLLOW_REJOIN` for the target Goblin
during this probe; the other Goblin did rejoin after its own player was moved
more than 800 tiles, so it is not part of the handoff claim. Both players were
returned to their pre-test areas. This is direct handoff and follow evidence,
but the samples are too coarse to certify a no-teleport trajectory, so the
schema-2 handoff gate and Milestone 1 remain formally incomplete. The local
RCON listener and password were removed, its helper deleted, and the local
server restarted with RCON disabled.
Schema-2 validation now requires at least five time-ordered handoff samples,
no gap over two seconds, no actor step over five tiles, an observed native
owner change and return, and explicit no-rejoin/no-position-write evidence.
The old record cannot satisfy that by relabeling its version or updating hashes.

2026-09-23 follow-up: private exact-state telemetry now records native
simulation owner with each one-second Goblin position sample; a focused Lua
boundary test passes. After a local-only restart, `fencefang_73` and
`bramblefang_92` each had one Goblin on two ordinary no-Storm clients. A
temporary localhost RCON probe staged only the players, then restored them.
The same `goblin.primary.fencefang_73` actor moved from approximately
`(10748.68,10574.62,1)` to `(10760.33,10575.67,0)` while native authority
changed from fencefang to bramblefang and back. Seventeen consecutive exact
samples in `reference/pz-milestone1-current-handoff.json` had a maximum gap
of 1,205 ms and a maximum 3-D step of 4.149 tiles. No target-Goblin
`FOLLOW_REJOIN` appeared in the server log, and the probe issued no Goblin
position write. This supports the *handoff gate only* for the telemetry source
hash recorded there; it does not recertify other changed source modules or
the nine-gate Milestone 1 record. The RCON listener and password were removed,
its temporary probes deleted, and the local pair was restarted with RCON off.

2026-09-23 stair-test precondition did **not** pass: a player-only relocation
to the historical staircase moved `fencefang_73` over 1,000 tiles from his
Goblin. The server emitted repeated `FOLLOW_REJOIN`, but the managed actor
stayed in its old cell under the other client's native simulation ownership.
The stair gate was not measured. This is a separate long-distance rejoin
regression to resolve before reusing remote test sites; it must not be counted
as stair or teleport acceptance.

While the local pair was running, bramblefang reported that his Goblin walked
into an exterior door instead of following outside. Installed
`ISLockDoor:isValid` permits keyless unlocking from a non-exterior square;
Goblin's adapter had required a matching key on every side. The adapter now
permits that vanilla inside-side case only when the managed actor stands on
the exact door edge, while retaining safehouse, barricade and outside-key
guards. It also logs a throttled `DOOR_ACCESS_BLOCKED` reason for future live
failures. The 101 focused work/access tests pass. After a disposable local
restart with server-side Storm and two ordinary no-Storm clients, bramblefang
visually confirmed that the same Goblin opened the exterior door, crossed it,
and followed outside. Exact-state positions then showed Goblin about 13 tiles
closer to the player's new location. The exact door lock field was not
inspected before this run, so the inside-key rule is source-aligned and
boundary-tested, while the live observation proves the current doorway
behavior—not the historical lock state or second-client/save replication.
Milestone 1 remains incomplete.

The separate long-distance rejoin path now has a server-only native transfer
candidate. Installed Build 42.20.4 bytecode shows that direct `setOwner(null)`
does not update the network owner's zombie list, whereas
`NetworkZombieManager.moveZombie(body, null, null)` does and schedules an extra
network update. The new Storm helper checks a loaded free destination, uses
that native transfer, teleports, then lets native `updateAuth` reassign the
simulator near the player. Server Lua uses it only for an expiring FOLLOW
rejoin request; ordinary clients require no Storm. The prior log line now
distinguishes completed `FOLLOW_REJOIN` from `FOLLOW_RECOVERY_REQUEST`.
The JDK 25 build and 145 focused Lua tests pass, but this is **not** a live
movement or replication pass until the disposable two-client session is
restarted and a far-away player is rejoined without a duplicate or lost
inventory. No production or published version has changed.

2026-09-23 live rejoin follow-up: the rebuilt JAR loaded on the disposable
Storm server; `rejoinfang_74` and `trailfang_74` connected from two ordinary
no-Storm clients, each with one Goblin. An authenticated temporary local RCON
probe moved only the players. With both players together, the engine assigned
`goblin.primary.rejoinfang_74` to trailfang's native simulation client. After
rejoinfang alone moved roughly 886 tiles away, the server logged one completed
`FOLLOW_REJOIN owner=rejoinfang_74 distance=885.7`. The *same* NPC ID and
generation-1 body appeared beside rejoinfang at approximately
`(10640.36,10265.17,0)`, under rejoinfang's native client ownership, while
trailfang retained one separate Goblin. Server runtime state reported two
companions, both inventory-persistent, with no inventory error or rejoinfang
respawn in the trace. Read-only captures of both actual game windows also
showed the named Goblin beside the matching player after transfer. This is
positive two-client visual/authority evidence for long-distance rejoin, not
proof that particular carried items survived: the disposable Goblin had no
separately inventoried test item. It does not certify the nine-gate Milestone 1
record. The temporary local RCON port and password were then cleared, and the
disposable server and both ordinary clients restarted with RCON disabled;
no production or published version changed.

2026-09-23 current-source route trace: a read-only 240-second exact-state
capture recorded 201 fresh snapshots with zero read errors from the disposable
two-client session. `rejoinfang_74` moved up to 76.6 tiles from the starting
position; the same named Goblin moved up to 75 tiles and ended 3.9 tiles away,
under rejoinfang's native simulation ownership. In a measured 24-second
segment between rejoin events, the owner moved 37.8 tiles and the Goblin
moved 38.5 tiles. The server logged three successful long-distance
`FOLLOW_REJOIN` operations after the owner outran the companion by about 30
tiles. A door on this route was locked, producing `DOOR_ACCESS_BLOCKED`, and
neither player nor Goblin changed floors in the capture. This supports
running-follow and rejoin behavior, but is not evidence for an unlocked
closed-door crossing or stair-follow, and teleport-assisted parts cannot
certify a no-teleport movement gate. The raw capture remains at
`C:\tmp\goblin-m1-route-20260923-b.json`; it is explicitly not an acceptance
record. The server also emitted two `ItemStats` packet exceptions while
autonomous Goblins carried aging food; that inventory replication defect is
separate from the navigation gate and remains to be resolved.
The raw-capture tool now hashes all 14 Milestone 1 source files and the server
JAR before and after collection, and refuses to write evidence if the
worktree, shared server/client1 package, or client2 package differs. A five-second
local provenance smoke capture and six focused acceptance/capture tests passed.
This tool improvement prevents a later live run from being attributed to
stale installed files; it does not satisfy any unperformed physical gate.

2026-09-23 house-route retest: two ordinary local clients again connected with
one Goblin each. The `trailfang_74` Goblin initially failed native FOLLOW at
two different nearby follow slots (`NAV_BLOCKED`, each after one six-second
repath), then physically approached the player around living-room furniture.
The subsequent player route from inside to the sidewalk showed the Goblin
outside too, with no server `FOLLOW_REJOIN`; a source-matched 120-second raw
capture recorded 101 fresh snapshots and zero read errors at
`C:\tmp\goblin-m1-house-door-20260923.json`. This is useful recovery and
house-route evidence, but the sampled positions do not by themselves certify
which door edge he crossed or every Milestone 1 gate. Another 180-second raw
capture at `C:\tmp\goblin-m1-detour-retest-20260923.json` recorded 151 fresh
snapshots; its second client exited with an external native `glfw.dll` access
violation during window-message processing and was relaunched. The live
follow-slot failure led to extending the bounded open-edge detour to blocked
`follow_slot` and `follow_detour` goals, not only blocked character goals.
The extension passed 146 focused Lua/access/work tests and the 64-record
catalog check. It was then staged into both disposable clients and restarted;
its own post-restart physical acceptance is still pending. Milestone 1 remains
incomplete, and `.03`, GitHub main, and Workshop remain untouched.

2026-09-23 follow-slot revision smoke: after staging the extension, the
disposable two-client server reported one player and one managed Goblin for
each of `rejoinfang_74` and `trailfang_74`, with ordinary clients and
server-only Storm. A 120-second source-matched capture at
`C:\tmp\goblin-m1-follow-slot-retest-20260923.json` recorded 101 fresh
snapshots and zero read errors. Trailfang moved on open ground while its
Goblin remained active, wandered during the idle interval, and ultimately
returned within roughly three tiles. No Goblin `NAV_BLOCKED` or
`FOLLOW_REJOIN` appeared in this run. Live input was detected in the client,
so automated control stopped; this run did not reproduce the blocked
furniture/doorway slot and cannot certify the new detour branch or Milestone 1.

2026-09-23 operator-controlled navigation follow-up: the disposable second
client was driven through a house entrance and back toward the road. A
source-matched 180-second capture at `C:\tmp\goblin-m1-alt-edge-live-20260923.json`
recorded 151 fresh positions and no read errors, with both actor IDs owned by
`trailfang_74`; Goblin visibly crossed the threshold with the player. A second
source-matched 120-second capture at
`C:\tmp\goblin-m1-indoor-follow-20260923.json` recorded 101 positions and
exposed a failure: the owner reached `(10686.5, 9361.5)` while Goblin remained
near `(10691.8, 9358.3)`. The client logged blocked FOLLOW slots and native
repaths with no progress, while the server repeatedly reported a locked
adjacent door edge. The first client also crashed twice in native `glfw.dll`
window-message processing during loading; no Lua error established a Goblin
cause, but the two-client acceptance gate was not available in this run.

The blocked-follow search now marks an alternate square visited only after a
valid entry edge is confirmed. A diagnostic run found the native path request
accepted while `ZombieIdleState` persisted and `bPathfind` was false. A
temporary path-flag experiment and actor-specific `testPathFindAdjacent` edge
rule were staged only in the disposable local copy. An exploratory
source-matched 90-second capture at
`C:\tmp\goblin-m1-pathflag-retest-20260923.json` showed the owner move from
`(10683.5, 9363.5)` to `(10675.5, 9360.5)` and Goblin from
`(10684.9, 9364.5)` to `(10681.9, 9360.6)` under client simulation
ownership, but Goblin then stalled at a high fence. With both experimental
changes staged, Goblin subsequently moved around the fenced area and onto the
road in an operator-controlled smoke check. A source-matched capture for that
post-diagnostic candidate at `C:\tmp\goblin-m1-final-open-road-20260923.json`
recorded 75 positions and another failure: the owner moved to
`(10665.5, 9344.5)` while Goblin stayed at `(10672.8, 9352.1)` after two
blocked native character paths. The detour branch did not engage. Both
unverified changes and the temporary native-state log were therefore removed
from the worktree; neither experiment is credited as an ability. The retained
alternate-entry BFS correction has a failing-before/passing-after unit test,
but its own live acceptance remains open. The 64-record Section 31 consistency
check passes, and Milestone 1 remains incomplete. Production `.03`, GitHub
main and Workshop remain untouched.

2026-09-23 native idle-wander follow-up: installed `ZombieIdleState.execute`
can choose a random nearby square and issue its own `pathToLocation` when a
non-useless zombie's state-event timer expires. Goblin's managed movement keeps
its body non-useless, so an active native FOLLOW path can be overwritten by
that idle-state path. The current candidate refreshes the native idle timer
only while a locally controlled Goblin has a managed destination and is in
`ZombieIdleState`; it does not move the actor or change combat/access states.
The focused Lua/access/acceptance run passed 78 tests. A source-hash-matched
disposable capture at `C:\tmp\goblin-m1-idle-guard-route-20260923.json` recorded
101 fresh server positions with zero read errors while the local player was
relocated along several road/grass points. Goblin closed the gap physically,
including from `(10668.4, 9344.7)` to `(10681.4, 9358.3)` after the player
returned near `(10682, 9361)`, without a `FOLLOW_REJOIN` log. The server-side
sample stream still contained an 11.62-tile step because its client-owned
zombie coordinates arrive in batches; this capture alone cannot certify
continuous movement or the nine-gate Milestone 1 acceptance. The local-only
3600-second autonomy-idle and RCON fixtures used to isolate the route must be
removed after testing. Nothing was changed on `.03`, GitHub main or Workshop.

2026-09-23 owning-client follow trace: the opt-in local client sampler now
records the managed Goblin's online ID, native simulation ownership and
actor/player positions at roughly 10 Hz, with matching source and installed
mod hashes. `C:\tmp\goblin-m1-astar-retest-20260923.json` captured 101 fresh
server snapshots without read errors. The matching owning-client extraction
`C:\tmp\goblin-m1-astar-owning-client-20260923.json` contained 2,026 samples
for online ID 9563, always `remote=false`. It caught an actual stalled FOLLOW
route and a 27.16-tile actor jump in 100 ms; the server logged
`FOLLOW_REJOIN distance=30.5`. That jump is a rejoin, **not** physical path
recovery, and cannot pass live scenario 9. A bounded A*-ordered detour search
did not resolve the stall. A subsequent local diagnostic at `(10778,9762)`
reported all four neighbors: three `not_free`, and the sole open exit
`(10778,9763)` `blacklisted` after an earlier full-target failure. The current
candidate separates `follow_detour` waypoint failure memory from full FOLLOW
target failure memory, allowing that physically open exit to be tried once as
an approach while still blacklisting a genuinely failed waypoint. The new
only-exit regression and 86 focused tests pass. A source-matched local run at
`C:\tmp\goblin-m1-detour-approach-live-20260923.json` captured 101 fresh
server snapshots; the matching owning-client extraction at
`C:\tmp\goblin-m1-detour-approach-client-20260923.json` contains 1,587 samples
for online ID 1763, always `remote=false`, with 176 moving steps and a maximum
observed step of 0.469 tiles. Goblin visibly followed outside the house, but
the local sync had removed the temporary 3600-second idle override; server
logs show FOLLOW/LOOT task switches during this run. It is therefore evidence
of physical movement, not isolated blocked-FOLLOW recovery or the full live
scenario 9 pass. The client trace flag was removed, and the disposable local
client/server pair was stopped after capture; no idle override remains in the
local bridge config. Milestone 1 remains open;
production `.03`, GitHub main and Workshop remain untouched.

2026-09-23 accepted local follow behavior: with `idle_seconds=3600` applied
*after* local staging, `C:\tmp\goblin-m1-isolated-follow-20260923.json`
captured 101 fresh server snapshots and
`C:\tmp\goblin-m1-isolated-follow-client-20260923.json` captured 1,607
owning-client samples (`remote=false`, maximum observed actor step 0.472
tiles). Goblin followed over open ground, then stalled about 15 tiles behind
the player. The client tried native character and alternate detour paths;
those calls were accepted but the actor made no further progress. A later
local diagnostic logged `native_state=ZombieIdleState pathing=false
bPathfind=false has_path2=false should_move=true collided=false` at a blocked
FOLLOW slot. The user then observed the practical behavior and explicitly
accepted the current movement as-is. This is user acceptance of the current
local build, **not** proof that specification scenario 9 (blocked-path
recovery without teleport) passes. No path-state experiment was promoted.
The temporary idle override and client trace flag were removed, and the
disposable pair was stopped. Production `.03`, GitHub and Workshop were not
changed.

The dated checkpoint notes below are chronological and retain their at-the-time
"incomplete" status; this current gate summary supersedes those earlier states.

Source specification: `Goblin_Abilities_V2_Referenced_Build_Spec.md`, supplied
2026-09-19. Follow milestones 0–10 in order; experimental driving is separate.

## Baseline captured 2026-09-19

- Local main: `ac74788f4b8a54f1b0520f173f7963a822c77e49`.
- Working branch: `codex/abilities-v2-runtime-catalog`.
- Existing unrelated map modifications and untracked character artwork retained.
- `python -m unittest discover -s tests -v`: **216 passed** (4.445 seconds).
  Includes Lua 5.1 boundary-double tests; these are not live engine acceptance.
- `node --test tests/test_web_map.cjs`: **24 regression assertions passed**.
- Java baseline boundary checks subsequently passed against actual engine and
  target Storm JARs: CompanionJobs 4, CompanionSeats 3, ServerSupport 23.
- `.03` read-only SSH check at 2026-09-19 16:56 UTC: service active,
  `PauseEmpty=true`. No configuration changes or restart performed.
- Installed game JAR SHA256:
  `80e405a4bfc42f6072e75b3735f458a6514143da011d3226007ded305a442f44`.
- Installed Goblin helper SHA256:
  `93300d7e9b659c5e1f49be335d702b7bf63d18aeb2921a6afd9b7a3d539cbf4f`.
- Workshop manifest SHA256:
  `e3192882936be0c04d79576497f8e7e230a89c928fcde90dae9719bb5bfa79b6`.
  This is a manifest-file hash, **not** an enabled-content fingerprint.

## Evidence boundaries

Maintain separate evidence labels: DOCUMENTED, REPO_EXISTING,
RUNTIME_RESOLVED, ENGINE_TESTED, PROPOSED, UNSUPPORTED.

- Existing chat commands and aliases must be traced from the actual parser.
- Proposed commands are inventory entries only, not registered handlers.
- Native APIs describe implementation candidates, not chat capabilities.
- Server/RCON administration is never a gameplay planner tool.
- All capability acceptance requires actor compatibility, authority, movement,
  material accounting, world changes, replication and persistence evidence.
- `getAllItems()` and `getAllCraftRecipes()` were executed by the default-off
  exporter inside the exact disposable `.03` content copy. The resulting 5,397
  item and 1,118 recipe records are captured and hash-bound; this still does not
  prove recipe callbacks or Lua/managed-IsoZombie compatibility.
- `Item.getTags()` returns a Java Set; recipe tags return a Java List. Do not
  assume Lua arrays or identical iteration APIs.
- CraftRecipe exposes `isRequiresPlayer()`, but a false value does not prove
  every nested recipe callback supports IsoZombie.

## Milestone 0 closeout

1. Captured exact game, Storm, enabled-mod content hashes and source provenance
   from a disposable copy of `.03`; production was not restarted or modified.
2. Ran the opt-in, developer-only read-only exporter inside that exact copy. It
   is isolated from chat/Qwen and normal startup and performs no gameplay action.
3. Captured 5,397 items, 1,118 craft recipes, 55 crops, 241 vehicle scripts with
   7,992 parts, 6 traps, 6 animals, 1,679 forage definitions, 21 fish, 41 lures,
   and effective moveable repair/scrap/tool tables. The two fishing raw-string
   exceptions remain explicitly classified; no alias was invented.
4. Inventoried 19 existing and 42 proposed capabilities. All 61 records contain
   semantic arguments, targets, installed/native call sites, public-reference
   links, authority, item/recipe resolution, permissions, completion criteria,
   replication/save, reconciliation and verified-version scope.
5. Kept `/goblin` commands, deterministic natural-language routes, proposed
   commands, Qwen intents, native APIs, loopback administration and RCON in
   separate inventories. Repository RCON integration is absent; proposed chat
   commands remain explicitly unregistered.
6. Strict catalogs and inventory consistency pass. Structural coverage now has
   zero gaps except the intentionally absent proof: 40 proposed abilities have
   no handler-level unit-test IDs and all 61 lack recorded multiplayer acceptance.
   Those gaps block each capability's completion, not the completed catalog.

Production, main, Steam Workshop, Qwen and Discord remain unchanged by this work.

## Milestone 1 candidate — awaiting live multiplayer acceptance

- Exact installed Build 42 bytecode confirms
  `IsoZombie.pathToCharacter(IsoGameCharacter)` delegates to the generic
  `PathFindBehavior2.pathToCharacter` path without an `IsoPlayer` cast in the
  inspected entrypoints. Long-distance FOLLOW now uses it with coordinate
  pathing as a binding fallback; nearby following uses one stable slot from an
  eight-position ring.
- Work approach search now evaluates the target, all eight radius-1 neighbors,
  and a radius-2 staging perimeter. It excludes unloaded, occupied, burning,
  blocked and temporarily blacklisted candidates. Radius-2 is staging only and
  cannot authorize a world mutation.
- No-progress recovery now performs one native repath, then returns a blocked
  result and blacklists that target/approach for a bounded 30 seconds. It never
  teleports. Door opening increments a replicated access revision so the
  current native client simulation owner immediately issues a fresh route
  without consuming the no-progress retry.
- Build 42's `PathFindBehavior2.pathNextIsSet/pathNextX/pathNextY` members are
  public fields in the installed JAR. Door routing now reads either fields or
  zero-argument methods for compatibility.
- Primitive ModData navigation state and coarse telemetry report path state,
  goal/approach, progress age, retry count, blocked reason/edge, simulation
  owner and last successful movement. Runtime blacklist tables remain bounded,
  expiring and non-serialized.
- 107 focused Lua engine-boundary tests pass, including native character follow,
  stable/alternate slots, one-retry termination, blacklist expiry, radius-2
  staging, path-next public fields and existing authority handoff. These are
  boundary-double tests, not live engine or second-client acceptance.
- Partial live evidence on 2026-09-19: a disposable Build 42.20.4 server with
  server-side Storm accepted two separate local clients (`horse`, `unicorn`),
  created exactly two named/visualized/persisted Goblins, and reported both
  native simulation owners as `client`. The ordinary executable also completed
  mod/checksum loading without client-side Storm before test-only automatic
  account entry was enabled. Exact telemetry showed a stationary horse slot at
  a stable 4.32-tile gap and physical unicorn Goblin position changes while the
  unicorn player position changed during entry. No Goblin Lua exception was
  logged. This is useful partial evidence, not the scripted acceptance gate.
- Remaining gate: deliberately move/run an owner, traverse a closed door, stage
  an obstructed work target, and hand simulation ownership to a nearby second
  client while recording before/after positions and native world state. Until
  then FOLLOW and Milestone 1 remain `complete: false`.

### Milestone 1 live acceptance checkpoint — 2026-09-19 23:11 EDT

- A disposable local Build 42.20.4 server ran with server-side Storm and two
  ordinary no-Storm clients. `mossclaw_7a3d` and `scrapfang_b841` each received
  one distinct generation-1 Goblin; no checksum mismatch occurred in the valid
  run. Test-only Lua and automatic login files were removed afterward.
- Closed-door FOLLOW passed on edge
  `10995,9701,0|10995,9700,0`: the probe verified the door closed before the
  order, wrapped the real `GoblinAccess.open` boundary, observed that boundary
  successfully open the exact door, and observed the managed IsoZombie cross
  it 3,900 ms later. An earlier run whose synthetic player placement did not
  replicate was rejected and is not counted.
- Durable radius-2 work staging passed for loaded target `10979,9671,0`. The
  target was structurally blocked, had three world objects, and had no valid
  radius-0/1 interaction square. Runtime selected actual stage
  `10977.5,9669.5,0`; Goblin physically reached it in 8,101 ms. Target object
  count and free/blocked state were unchanged before arrival.
- Evidence is recorded in `reference/pz-milestone1-live-acceptance.json`, bound
  to the tested navigation/access/spawner source hashes. This proves the closed
  doorway and durable radius-2 gates, not all of Milestone 1.
- Remaining Milestone 1 live gates are furniture detour, stairs, owner running
  through a building, native failure/repath/blacklist recovery, and an observed
  simulation-ownership transfer between nearby clients. Milestone 1 therefore
  remains `complete: false`.

### Milestone 1 live acceptance checkpoint — 2026-09-20

- A disposable ordinary no-Storm client pre-staged `pathfang_f2a1` and its
  managed actor on a verified straight 18-tile outdoor corridor. Pre-staging is
  only a test precondition and is not counted as movement. After measurement
  began, the owner moved 17.01 tiles and Goblin moved 8.72 tiles in 8,033 ms,
  ending at an 8.70-tile gap. Maximum observed Goblin step was 0.04 tile and no
  teleport occurred. This accepts open-terrain running FOLLOW, not running
  through a building.
- The same disposable probe imposed a reversible movement obstruction with
  `setCanWalk(false)`, `setUseless(true)` and `setSpeedMod(0.0)` while leaving
  the native path intact. Runtime issued exactly one native repath, returned
  terminal blocked reason `no progress after native repath`, and retained a
  bounded route blacklist. At 31,050 ms the probe restored the actor's movement
  flags; Goblin resumed 0.81 tile of physical movement without teleport. This
  accepts the no-progress/repath/blacklist-expiry gate.
- Exact markers and the test boundary are recorded in
  `reference/pz-milestone1-live-acceptance.json`. The disposable probe never
  replaced or cancelled the accepted native route and was removed afterward.
- Added read-only dedicated-server navigation telemetry from the installed
  `IsoZombie.getOwnerPlayer()` API. In a two-client ordinary no-Storm run,
  Horse's Goblin initially reported native owner `horse`. A temporary localhost
  RCON precondition moved `unicorn` onto the actor and `horse` 20 tiles away;
  the engine changed native owner to `unicorn` at an observed 0.49-tile versus
  20.41-tile gap. After the Goblin physically returned to Horse, the engine
  reassigned native owner to `horse` at a 2.77-tile gap. No ownership field or
  Goblin position was written. Both players were restored afterward and both
  companions resumed FOLLOW under their own client authority. This accepts the
  simulation-ownership handoff gate.
- A loaded indoor chair at `10815,9986,0` was selected from live world objects
  as a blocked movement square. With only the owner staged across it, the
  managed actor moved 7.402 tiles, used the free square one tile west of the
  chair, crossed from the south side to the north side, and never occupied the
  chair square. Native authority remained with Horse and no `FOLLOW_REJOIN`
  occurred during measurement. This accepts the furniture-detour gate; coarse
  one-second samples are not used to claim a per-frame teleport bound.
- Door regression diagnosis found that installed
  `IsoDoor.ToggleDoorActual(IsoGameCharacter)` mutates and synchronizes an
  ordinary door, then dereferences an `IsoPlayer` cast that is null for the
  managed IsoZombie. That late exception made Access report failure and left
  the simulation-owning client on a stale blocked path. Goblin now uses the
  player-free installed methods: `ToggleDoorSilent` plus full
  `syncIsoObject` for ordinary doors and native `toggleDoubleDoor` /
  `toggleGarageDoor` for groups. It verifies post-state and sends a replicated
  access revision to the movement owner for one immediate native repath.
- A clean disposable server-side-Storm run with two ordinary no-Storm clients
  opened/unlocked a locked ordinary door and every segment of a locked
  four-piece garage door. Server and both clients observed the garage group
  open and unlocked; physical client-owned movement resumed, no
  `FOLLOW_REJOIN` occurred, and no Goblin Lua exception was logged. Barricaded
  or destroyed doors remain rejected. Safehouse denial is unit-tested via
  `SafeHouse.playerAllowed(GoblinOwner)` but has not yet been live-accepted.
  Constructed `IsoThumpable` door variants and door save/reload remain explicit
  proof gaps.
- A later client-owned-path regression reproduced the missing server
  `PathFindBehavior2` edge. A disposable server-only setup closed the loaded
  four-segment garage group with Horse's Goblin at the threshold. The new
  adjacent-edge fallback found the door, opened it, advanced the replicated
  access revision from 0 to 1, and the actor physically crossed edge
  `10708:9366:0|10709:9366` without a Goblin position write or
  `FOLLOW_REJOIN`. The same build rejects follow slots separated from the
  owner by a locally observed wall, closed door or window, preventing false
  arrival on the wrong side before access handling can run.
- Remaining Milestone 1 live gates are stairs and owner running through a
  building. Milestone 1 remains `complete: false`.

## Milestone 1 local acceptance checkpoint

- A real three-tile vanilla staircase was identified at
  `10742,9458,0` through `10742,9456,0`, with its upper landing at
  `10742,9455,1`. Horse's Goblin ascended from z0 to the z1 landing and later
  descended through fractional stair Z positions (`0.190`, then `0.010`) to
  z0. Native ownership remained with Horse, the respawn-rejoin sequence was
  inactive, and no Goblin position write occurred.
- Horse then ran 14.386 tiles through the loaded building. Goblin followed the
  route, entered the installed engine's native `ClimbThroughWindowState` at
  the intervening boundary, resumed `PathFindState`, and closed to a 3.823-tile
  stable follow gap without `FOLLOW_REJOIN` or a Goblin position write.
- The acceptance run used two ordinary no-Storm clients against the local
  server-side-Storm session. Together with the earlier open-terrain, door,
  furniture-detour, staging, stuck-recovery, ownership-transfer, respawn and
  two-player/two-Goblin observations, all Milestone 1 requirements and relevant
  live scenarios are locally accepted.
- Milestone 1 is now `complete: true` for local acceptance. Nothing from this
  checkpoint has been committed, pushed, published, deployed or changed in
  production. Temporary acceptance probes and local RCON were removed, then a
  clean server-side-Storm/two-client restart auto-connected `horse` and
  `unicorn` without credential prompts and spawned exactly one Goblin for each.

## Milestone 2 local acceptance checkpoint

- Added an additive server-side capability registry around the existing
  `FARM`, `CRAFT`, `REPAIR_VEHICLE` and `CLOSE_CURTAINS` handlers. Each
  registration declares destructive policy, offline/owner requirements,
  preparation, update, cancellation, snapshot and material/tool requirements.
  Access, transport and later-milestone abilities remain on their existing
  paths until their own milestone; no working handler was rewritten merely for
  style.
- Persisted job payloads now pass a bounded primitive-only validator. Functions,
  userdata, cycles, excessive depth/entries and non-finite numbers are rejected.
  Runtime engine references remain in a weak body-keyed table and are excluded
  from snapshots.
- Job updates now return `{done, success, code, detail, progress}`. Terminal
  failures use the specification's standard codes, engine exceptions fail
  closed as `ENGINE_ERROR`, and the latest primitive result is available in the
  body snapshot for deterministic higher-level reasoning.
- The initial full-suite baseline found two Milestone 1 regressions: close-range
  follow fell back onto the owner when squares were unavailable, and an older
  door test still expected locked doors to be rejected. The close-range path now
  waits for loaded squares; the door test now verifies the intended all-tools
  unlock/open behavior.
- A disposable Build 42.20.4 two-client run loaded four registered capabilities
  on server-side Storm while both ordinary clients remained Storm-free. A
  server-only acceptance hook supplied exactly one `Base.Log` to Horse's
  persistent Goblin and submitted one `SawLogs` job through the normal internal
  Brain boundary. The registry emitted `WORKING` then `COMPLETE`; the log count
  changed 1 -> 0 and the plank count changed 0 -> 3 with no capability/job
  error. See `reference/pz-milestone2-live-acceptance.json`.
- Milestone 2 is locally accepted as `complete: true` for the framework itself.
  This does not mark the individual farm, repair or curtain abilities physically
  multiplayer-complete, does not claim second-client inventory observation, and
  does not advance any later milestone. Nothing was committed, pushed,
  published, deployed or changed in production.

## Initial catalog implementation checkpoint

- Added a secret-filtered installed-file fingerprint collector and a catalog
  structural validator with exact-ID/explicit-alias resolution. **19 focused
  Python tests pass**. Runtime validation correctly fails because the real
  `pz-items.json` and `pz-recipes.json` exports do not exist yet.
- SSH cannot read every Storm file. User restored signed-in Proxmox access;
  read-only root-console hashing then covered 32,897 files / 680,722,174 bytes.
  See `reference/pz-installed-fingerprint.json`; configured content is explicitly
  not labelled the effective loaded-mod registry.
- Actual `.03` game build: 42.20.4 b0bbce05d5. Server Storm filename reports
  2.10.11; local Storm reports 2.11.1. Do not treat local results as exact target
  Storm evidence until staging is reconciled.
- Added a partial command inventory separating player, admin-only Goblin,
  proposed, native API and RCON categories. Added an initial CRAFT compatibility
  record documenting the installed native IsoPlayer cast hazard.
- Default-off loaded-registry exporter implemented. Full source and tests compile
  with Java 25 against the hash-matched game JAR and `.03` Storm 2.10.11 JAR.
  The exporter adds 10 passing serialization/file-boundary checks (40 Java checks
  total with the baseline tests). Windows symlink and POSIX permission checks
  were skipped by their test harnesses; these are not claimed as passed.
- Compiler: portable Eclipse Temurin 25.0.4.1+1, obtained through the official
  Adoptium API; archive SHA256
  `00c847d804f4a78e9f04f2683faf14fed898535b177b7fc704486cb0284e9283`.
  No machine-wide installation or Java settings changed. The target Storm JAR
  was copied read-only into a temporary validation directory, not the repo or
  local Workshop installation. No packaged production helper was overwritten.
- Focused safety review completed. Corrections add explicit fluid/energy resource
  semantics, exact item lookup identity, required catalog fields, exact exported
  file hashes, export-set coherence and rejection of empty source roots. The
  effective enabled-content fingerprint remains UNKNOWN, not a mod-ID-list hash.
- User approved a disposable exact local copy. Temporary private server archive
  contained only vanilla scripts/Lua and configured Workshop content; it was
  copied with matching SHA256 and then removed from `.03`. Local extracted files
  independently match the server aggregate: 32,897 files / 680,722,174 bytes.
  Windows extended paths were necessary to enumerate deeply nested assets.
- Actual runtime export, effective enabled-content fingerprint, full capability
  inventory and real multiplayer evidence remain outstanding. No catalog files
  are fabricated from static definitions.

## Disposable runtime checkpoint — 2026-09-19 17:51 UTC

- Captured actual loaded registries on a disposable Windows dedicated server:
  **5,397 items and 1,118 craft recipes**, with all 68 configured mod IDs observed.
  Game build is `42.20.4 b0bbce05d5`; Storm is the captured `.03` 2.10.11 build.
- Script checksum `a67e41bbb66f4d9d5cfa3717f70c82e6` exactly matches `.03`'s
  existing 2026-09-15 startup log. This supports the registry-content match, but
  is not a substitute for the pending effective SHA256 content manifest.
- Saved the unmodified engine exports to `reference/pz-items.json`,
  `reference/pz-recipes.json`, and `reference/pz-runtime-fingerprint.json`.
  Structural and export-byte-integrity validation passes. Strict
  `--require-runtime` correctly fails on missing effective enabled-content proof.
- All 19 existing toolkit full types and five weapon/uniform full types resolve,
  are enabled and are not obsolete. `Base.SawLogs` resolves by exact ID and name;
  its managed-IsoZombie compatibility remains UNKNOWN.
- Runtime lookup also resolves `Base.BoltCutters`, `Base.HandDrill`,
  `Base.CarBatteryCharger`, `Base.File`, `Base.Pliers`, and `Base.SheetMetalSnips`.
  None is newly enabled as a gameplay capability. Display text `Axe` resolves
  to `Base.Axe_Old` in this export; aliases must not be inferred from spelling.
- Test launch fixes were confined to staging: quote dotted Java properties;
  include the hash-matched `stdlib.lua`; use physical media/mod copies because
  native checksum scanners canonicalize junctions inconsistently; point Storm's
  installed `storm.launcher.mods` option at the isolated cache mod directory.
- Exact build metadata now uses installed `Core.getVersion()`, whose bytecode
  includes patch build and revision. `getVersionNumber()` returned only `42.20`.
- Local test used loopback `127.0.0.1:17261`, Steam disabled, no players,
  Goblin gameplay/autonomy disabled, and no bridge service. Sent `quit` after
  exporting. No production restart, Workshop update, commit or publication.
- Revalidation: 19 catalog/fingerprint Python tests and 10 exporter Java checks
  passed; Java's symlink check remains skipped on this Windows environment.
  Both staging PowerShell files parse without errors. These are not multiplayer
  ability acceptance tests. Milestone 0 remains incomplete; Milestone 1 is not
  started. Continue with effective content provenance and compatibility inventory.

## Selected-content and access audit checkpoint — 2026-09-19 18:01 UTC

- Added bounded read-only hashing of runtime-selected common/version roots.
  The actual export reports `CONTENT_VERIFIED`; strict catalog validation now
  passes for 5,397 items / 1,118 recipes, build 42.20.4 b0bbce05d5.
- Independent file comparison verified all 68 loaded mods and both vanilla source
  trees against the captured `.03` content. Only the explicitly supplied candidate
  helper differs. See `reference/pz-stage-reconciliation.json`; production's
  selected-content digest is not falsely equated to the candidate helper digest.
- Fingerprint `b8a38a016a9959a807aaa72bb5d5c6c02ea6657b5245d626cad4d16453507cb2`;
  original captured selected-mod digest
  `749a839d215ae7c2f6a4a57ec23fc17e8d5294c33995d067cedc48b7d7869bfa`.
- Added source/authority/material/replication/compatibility records for OPEN_DOOR,
  OPEN_WINDOW and CLOSE_CURTAINS. Found a native door post-mutation nullable-player
  hazard, the existing route-door field/method mismatch, missing window animation
  proof, and an uncovered door-attached curtain variant. Gameplay remains unchanged.
- 103 focused Python tests passed (catalog, fingerprint, reconciliation, existing
  house/jobs/work boundaries). New content-hash Java checks: 10; exporter checks: 10
  passed; exporter symlink check still skipped on Windows. These do not constitute
  live managed-actor or second-client acceptance.
- Disposable server shut down cleanly after export; no production changes. The
  preceding export was retained in the disposable stage before replacing the
  generated repository catalogs. Milestone 0 remains incomplete: continue the
  remaining existing/proposed capability inventory and catalog-specific checks.

## Vehicle compatibility checkpoint — 2026-09-19

- Added existing ENTER_VEHICLE, EXIT_VEHICLE and REPAIR_VEHICLE records, bringing
  the partial inventory to seven capabilities. None is marked engine-tested or
  complete. Installed passenger and repair Lua sources have recorded SHA256s.
- Native vehicle entry/exit packet setters cast their actor to IsoPlayer. Existing
  Goblin transport instead uses enterRSync and shared roster-backed passenger
  geometry, with Storm guards for occupied managed-NPC seats. Initialization of
  those guards is not evidence of multiplayer seat-race correctness.
- Exit currently ignores detach failures and does not verify the final vehicle,
  occupant and position postconditions. Fixed 700ms transport phases do not prove
  the native passenger animation finished. These are recorded gaps, not fixes.
- Base.Wrench and Base.EngineParts resolve in the actual loaded catalog. Native
  repair's server XP path casts to IsoPlayer; the existing adapter bypasses it.
  Repair still needs a separate fixing-definition/input inventory, removal of
  guessed Base namespaces, hood/skill eligibility review, partial-failure
  reconciliation and physical movement/consumption/replication acceptance.
- 57 focused transport/jobs/catalog Python tests passed; strict runtime catalog
  validation still passes. Mock tests do not establish native animation or
  multiplayer compatibility. No gameplay edits, production changes, restart,
  commit, push or publication occurred in this checkpoint.
- Milestone 0 remains incomplete. Continue the remaining existing/proposed
  capability inventory before implementing Milestone 1.

## Farming compatibility checkpoint — 2026-09-19

- Added FARM with separate plow, sow, water, harvest and tend evidence. Eight
  existing capability records now exist; none is marked complete. Recorded exact
  installed hashes for the native farming system, plant object and four timed
  actions, plus the current Goblin farming module.
- Confirmed the loaded registry resolves HandShovel, Scythe, CabbageSeed and
  Cabbage. This is not full crop coverage: the effective Lua crop property table
  and all seed/input/output IDs still require export, including Workshop overrides.
  Crop season-learning identifiers must not be confused with craft recipe IDs.
- Native sow explicitly sends inventory removal and assigns a player owner;
  Goblin's path does neither here. Native fluid watering explicitly syncs the
  item after changing its amount; Goblin's fluid path does not. Plant saveData
  transmits world-object mod data, which alone does not prove inventory sync.
- Native harvest creates and transmits outputs before clearing produce state;
  partial exceptions need reconciliation. The flower branch accesses actor stats.
  Neither generic Lua signatures nor mocks establish managed-actor compatibility.
- Existing tend only waters and harvests; it does not fertilize, weed, cure,
  sow or remove dead plants. FARM uses Bob_IdleLooting_Low rather than distinct
  vanilla digging/pouring/crop-height animations. These remain implementation gaps.
- All 24 existing job tests passed, including six farming tests. JSON inventory
  checks confirmed unique IDs, no overlap with the remaining-existing list and
  no completed-capability claims. Installed Java signatures for Remove,
  UseAndSync and FluidContainer.adjustAmount were checked against the matching JAR.
- No gameplay changes or external writes. Next: finish remaining existing work
  and command inventories, then proposed capability compatibility and additional
  runtime Lua/fixing registries before the Milestone 0 gate can pass.

## Building and fortification checkpoint — 2026-09-19

- Added BUILD and FORTIFY, bringing the partial inventory to ten records. Confirmed
  Base.Hammer, Base.Plank and Base.Nails in the loaded registry. Recorded hashes of
  GoblinWork and installed barricade, wooden wall/container and build-util sources.
- Inspected installed IsoBarricade actor overload/addPlank bytecode: position
  selects the side; actual plank condition and actor strength determine board
  health. These entrypoints have no IsoPlayer cast, but nested execution and
  multiplayer compatibility remain unproven. Inspected setIsContainer(true): it
  creates a real ItemContainer and reads sprite capacity, not merely a flag.
- Existing fortification is wooden boarding of loaded windows in a 17x17 area on
  the saved base floor, not whole-house/door/metal fortification. Existing building
  is three custom blueprints with fixed health, not general native construction.
  Native placement, construction flags, need: salvage metadata and lifecycle
  checks are not reproduced completely by the current adapter.
- Reproduced a conditional refund hazard using the existing Lua fixture: wrap
  IsoBarricade.AddBarricadeToObject so its returned addPlank increments planks then
  throws; execute a stocked FORTIFY job at clock and clock+5000. The installed
  board remains, World.materials still finds its refunded plank and two nails,
  and no completion is recorded. This is a boundary failure-injection result,
  not evidence the native engine throws that exception in normal production.
- Public IsoBarricade/IsoThumpable docs were checked for discovery; installed Lua
  and the hash-matched Java implementation remain authoritative. 41 existing
  work tests pass; JSON IDs are unique and absent from the remaining inventory.
  Those mocks do not establish actual world physics or second-client results.
- No gameplay modifications or external writes. Milestone 0 remains incomplete;
  finish movement/loot/combat/control inventory and effective Lua/fixing registry
  coverage before advancing the milestone gate.

## Movement and control checkpoint — 2026-09-19

- Added FOLLOW, internal MOVE_TO, WAIT and SET_BASE; fourteen existing capability
  records now distinguish implementation evidence from absent multiplayer proof.
  MOVE_TO is not advertised as a raw-coordinate chat command; SET_BASE records
  the authenticated player's position, not a safehouse claim or building scope.
- Confirmed installed IsoZombie.pathToLocationF returns void and may early-return
  at bytecode offset39 during allowRepathDelay in path/walk states. Therefore the
  current protected-call success is not proof a native path was submitted.
  Vanilla ISPathFindAction handles BehaviorResult.Failed/Succeeded explicitly;
  Goblin uses geometric arrival/progress instead and has no terminal retry bound.
- Movement authority is gated by server getOwner()==nil or client
  isRemoteZombie()==false. Server roster goals feed controlling-client work
  movement; FOLLOW recomputes the owner's goal. No ownership-handoff or zero-player
  simulation acceptance is inferred from these checks.
- Follow spacing has no stable group slots; clearance picks a free but not
  path-tested outward square. If no clearance candidate exists, nil can be treated
  as arrived despite inadequate separation. Normal stuck recovery does not use
  teleport; respawn rejoin is a separate expiring sequence-gated path.
- WAIT is a persisted stop order, not native rest/sleep or endurance recovery.
  Base set/clear updates saved owner metadata and live body fields; physical
  delivery and save/reload acceptance remain separate requirements.
- 54 focused jobs/companion-contract/transport tests passed. JSON checks confirm
  fourteen unique records, no overlap with remaining existing actions and no
  completed-capability claims. These mocks/static checks are not engine acceptance.
- No gameplay edits or external writes; Section 31 remains incomplete. Remaining
  existing inventory: return/delivery, loot, attack, equip and speech, followed by
  proposed actions and runtime Lua/fixing catalog coverage.

## Loot, delivery and equipment checkpoint — 2026-09-19

**Correction from the subsequent startup audit:** the weapon-conflict inference
below was incomplete. Bootstrap installs Defense's shotgun override before runtime
starts. The pistol-delivery fixture remains valid for a pistol item, but does not
prove the initialized mod creates/delivers/recreates pistols. See next checkpoint.

- Added LOOT, RETURN_TO_BASE and EQUIP; seventeen partial existing records now
  exist. ATTACK and SPEAK remain, followed by the proposed capability inventory
  and additional effective registry coverage. No ability is marked complete.
- Compared installed ISTransferAction/ISDropWorldItemAction with World.take and
  Loot.deposit. Existing adapters do not reproduce all native special-item,
  radio, floor-weight, equipment-removal and inventory-sync paths. Category loot
  is not exact FETCH_ITEM; base delivery only selects a container on the exact
  base square, then falls back to ground. Rejected/partial operations need results
  and post-mutation reconciliation, not only successful protected calls.
- Found a current-worktree equipment conflict: Config.weaponType is
  Base.DoubleBarrelShotgun, while Body.ensureWeapon hard-codes Base.Pistol3,
  ignores requestedType, creates it if missing and grants unlimited ammo.
  Both IDs resolve in the catalog; that does not make the behavior compliant
  with the specified shotgun exception. Loot protection uses Config.weaponType.
- Boundary reproduction: with existing CompanionWorkTests fixture, add one
  Base.Pistol3 to actor inventory; Loot.hasCargo returns true; Loot.deposit
  returns success/moved=1, removes it from actor and adds it to base ground.
  Combined with inspected ensureWeapon, this exposes a delivery/recreation risk.
  This is worktree source plus Lua-fixture evidence, not a new production claim.
- 41 existing work tests passed. JSON checks confirm seventeen distinct records
  with no overlap in remaining existing inventory. The tests stub Body, so their
  passing equipment checks do not invalidate the real Body.ensureWeapon mismatch.
- Used focused usage-efficient routing; no gameplay edits, restart, production
  modification, commit, push or publication. Continue Section 31 before Milestone 1.

## Combat, speech and startup correction — 2026-09-19

- All nineteen existing action names now have first-pass evidence records.
  This is NOT completed Section 31: native call-chain gaps, proposed actions,
  effective Lua/fixing registries, schema checks and physical evidence remain.
- Corrected EQUIP: Bootstrap.start calls Defense.install before Runtime.start.
  Defense replaces Body.ensureWeapon/refillWeapon with shotgun implementations.
  Earlier inspection stopped at the legacy Body module and overstated the mismatch.
- Added test_defense_override_replaces_real_legacy_body_weapon. Unlike other work
  fixtures, it loads real Body, installs Defense, confirms function replacement,
  equips actual Base.DoubleBarrelShotgun in the fixture, creates no Pistol3, and
  confirms the shotgun is not delivery cargo. Native engine acceptance still absent.
- ATTACK audit records server direct Hit, line-of-fire/range/owner leash checks,
  windup/cooldown, health postconditions and independent client animation cue.
  Installed Hit signature confirmed; nested actor casts/authority/replication need
  further investigation. A pre-impact visual cue can outlive a cancelled damage
  attempt. Missing health reads are not strong success proof.
- SPEAK records server emission, owner-local chat, actor-generation bubbles and
  bounded pending UI queue. Send success is not display receipt; queue needs chat
  context. Exact-last-key deduplication is not monotonic sequence rejection.
  Conversational/Qwen integration remains separate from physical action success.
- 57 work/contract tests passed, including the new real-Body override test. The
  first targeted run failed on a missing fixture-local Config binding, corrected
  by requiring the actual Config module; assertions were not weakened.
- Inventory parses with nineteen unique existing records and no completion claims.
  Production, GitHub and Workshop remain unchanged; only inventory/docs/test edits.

## Inventory consistency guard — 2026-09-19

- Added tools/check_goblin_inventory.py, invoked with
  `python -m tools.check_goblin_inventory`. Checks unique/disjoint existing and
  proposed inventory IDs, existing-command task mappings, referenced workspace
  files/hashes, and required items against enabled/nonobsolete loaded definitions.
- This is deliberately not an acceptance gate: it rejects complete/engine-tested
  claims until a real physical-evidence review mechanism is available. Text in an
  evidence array and item registry presence cannot certify an ability. It does
  not yet prove installed-source hashes, nested API compatibility, handler reach,
  exhaustive schema fields or the full specification inventory.
- Eight new tests cover partial-state acceptance, duplicate/overlap rejection,
  false completion, unsupported engine-test claims, invalid item IDs/states,
  stale/outside-workspace source references, proposed-task leakage and actual
  repository consistency. Together with catalog tests: 26 passed.
- Current result: 19 first-pass records, zero unaudited existing names in the
  current list, 42 proposed names still awaiting first-pass entries. Explicit gaps
  inside the existing records remain unresolved. Section 31 is still incomplete.
- No gameplay or production changes. Next work remains proposed subsystem
  inventories and effective crop/fixing registry export, not milestone promotion.

## Proposed generator inventory — 2026-09-19

- Added proposed INSPECT_GENERATOR, REFUEL_GENERATOR and MAINTAIN_GENERATOR
  records from captured installed ISGeneratorInfoAction, ISAddFuel and
  ISFixGenerator. No command or handler was enabled. Twenty-two records now exist;
  thirty-nine proposed names remain without first-pass records.
- Generator information's vanilla action is player-screen UI, not a headless
  NPC implementation. Native fuel/capacity/condition/activation getters and fuel/
  condition setters were confirmed in the matching installed JAR.
- Refuelling consumes the lesser of carried fluid and remaining capacity and
  syncs both item and generator. Container-definition presence does not prove
  fuel contents or eligibility; complete context-menu and sync paths remain open.
- Maintenance uses one ElectronicsScrap, condition gain4+Electricity/2, and native
  XP/timed-queue behavior needing managed-actor review. No reusable tool is
  required in the inspected action; no invented tool requirement was introduced.
  Base.ElectronicsScrap and Base.PetrolCan resolve enabled/nonobsolete.
- Eight inventory tests passed and consistency checker passes. These records
  remain proposed, incomplete and without physical/MP acceptance. No gameplay,
  production, GitHub or Workshop changes.

## Proposed medical inventory — 2026-09-19

- Added TREAT_PLAYER, TREAT_SELF and FETCH_MEDICAL; twenty-five first-pass records,
  thirty-six proposed names remaining. No implementation or acceptance claimed.
- Inspected installed bandage/disinfect/stitch/splint completion paths. Doctor
  username, health-cheat/role checks, XP and player-stat sync are not safe to infer
  from an IsoGameCharacter signature. Treatment of a player differs from treating
  Goblin: getBodyDamage simply returns a field, not a supported NPC wound model.
- Loaded Bandage, RippedSheets, Disinfectant, SutureNeedle and Splint IDs resolve;
  alternatives, fluid contents and treatment eligibility remain separate checks.
  Noted disinfectant completion's amount/division edge cases for full eligibility
  audit rather than copying its mutations into a new adapter.
- Existing medical-category looting is not an exact-quantity suitable-supply fetch.
  Inventory consistency checker passes; no new gameplay tests claimed and no
  production/Workshop/GitHub changes. Continue remaining proposed subsystems.

## Proposed tailoring inventory — 2026-09-19

- Added PATCH_CLOTHING and REPAIR_CLOTHING from captured ISRepairClothing and
  ISRemovePatch plus matching Clothing.addPatch bytecode. Twenty-seven records;
  thirty-four proposed names remain. No new command or gameplay handler.
- Needle, Thread, RippedSheets, DenimStrips and LeatherStrips resolve in registry.
  Exact garment/fabric eligibility still requires effective definitions. Needle
  is reusable; fabric and thread are consumed by the native action.
- addPatch uses a guarded IsoPlayer-only worn-clothing sync branch. Its full
  restoration branch can return before that sync branch. Neither path proves
  correct NPC worn-item replication; UI, XP and partial-mutation recovery need
  adapters and physical tests. Do not replace the protected visual-body item.
- Inventory consistency checker passes. No broader tests rerun for these
  evidence-only records; no completion, engine acceptance or production changes.

## Proposed wood-work inventory — 2026-09-19

- Added CHOP_WOOD and GATHER_WOOD; twenty-nine records, thirty-two proposed names
  remain. Inspected native ISChopTreeAction and IsoTree.WeaponHit entrypoint.
- Native chopping is event-driven, including tool wear and tree health damage;
  destruction calls toppleTree. No player cast in inspected WeaponHit entrypoint,
  but nested wear/topple, muscle strain/endurance and multiplayer paths remain
  unaudited. Do not synthesize logs or use instant-action tree-health shortcuts.
- Base.HandAxe resolves with base:choptree tag; Log and Plank resolve. Gathering
  existing wood is a transfer task, distinct from chopping or sawing/crafting.
- Inventory checker passes. No handler enabled or new physical acceptance claim;
  no production, GitHub or Workshop changes.

## Proposed logistics inventory — 2026-09-19

- Added SORT_STORAGE, STOCKPILE, DELIVER, MOVE_SUPPLIES and FETCH_ITEM against
  specification Section8 and existing World/Loot transfer implementation.
  Thirty-four records; twenty-seven proposed names remain.
- Explicitly separated current all-cargo base/feet deposit from selected-item
  delivery, exact-item fetch, persistent category containers, multi-trip transfers
  and stockpile minimums. None of those proposed policies exists merely because
  AddItem/Remove and broad loot filters exist.
- Required evidence includes safe persistent container identities, mutation-time
  permissions/locks, actual movement, conserved item identities, final stock
  recount after concurrent changes, interruption recovery and both-client state.
  Unloaded stock is unknown, not zero; a full assigned container must not silently
  change an explicit delivery request into a ground drop.
- Inventory consistency checker passes. No gameplay or production writes and
  no acceptance claims; proceed with remaining proposed subsystem evidence.

## Cleaning and corpse handling inventory — 2026-09-19

- Added CLEAN_BASE, MOVE_CORPSE and DISPOSE_CORPSE. Thirty-seven first-pass
  records, twenty-four proposed names remaining. Existing foundation unchanged.
- Resolved eight enabled cleanstains-tagged tools from runtime catalog. Inspected
  native cleaner-fluid consumption, item sync and stain-removal calls. Content
  eligibility and native world sync still require compatibility/physical tests.
- Human corpse movement uses native dragging and lastPlayerGrabbed player IDs;
  animal corpse carry uses a different inventory path. These are not equivalent
  to generic loot transfers, and no player identity spoofing is authorized.
- Burial and burning mutate grave/corpse/world state before later steps. Recorded
  explicit disposal permission, real fuel/ignition costs, identity and partial
  failure requirements. Generic cleaning does not authorize silent corpse deletion.
- Inventory consistency checker passes; no gameplay handler, production change
  or physical acceptance claim. Continue remaining proposed actions.

## Vehicle fuel and battery inventory — 2026-09-19

- Added REFUEL_VEHICLE and CHARGE_BATTERY: thirty-nine first-pass records,
  twenty-two proposed names remaining. This is not completed compatibility or
  physical acceptance; Milestone 0 remains open.
- Inspected installed canister/pump timed actions and charger connect, activate
  and removal actions. Canister validation returns true; pump validation only
  checks vehicle area. Neither substitutes for server permission, safe reach,
  current fuel eligibility and conserved transfer verification.
- Pump updates round tank litres down and remaining pump units up; completion
  sets tank target without itself finalizing pump debit. Actual authoritative
  update sequencing, power eligibility and fractional conservation remain to
  be proven, not assumed broken or supported from source alone.
- Charger activation is not evidence of charging. Removal clears/syncs the
  charger before inventory insertion; empty/occupied branches can return true.
  Battery identity, insertion failure recovery, native power/time simulation and
  client replication require dedicated tests. Charger item resolves in catalog;
  compatible battery identities remain pending.
- Inventory checker passes. No gameplay changes, production writes, publication
  or multiplayer acceptance claims.

## Vehicle part compatibility inventory — 2026-09-19

- Added VEHICLE_INSPECT, VEHICLE_SERVICE, REMOVE_PART, INSTALL_PART,
  REPLACE_PART and CHANGE_TIRE. Forty-five first-pass records, sixteen proposed
  names remain; actor compatibility and physical acceptance remain incomplete.
- Matched installed jar signatures and bytecode: canInstallPart/canUninstallPart
  accept IsoGameCharacter but dispatch part-defined Lua test callbacks. Installed
  default callbacks call getItems(chr:getPlayerNum()); getContainers reads player
  inventory/loot UI backpacks. This is a concrete headless-NPC dependency, not
  proof the generic Java signature supports the complete operation.
- Install/remove completion mutates inventory/part, then calls addMechanicsItem,
  declared on IsoPlayer (absent from inspected IsoGameCharacter declaration).
  Both also use player-oriented XP/results. A future adapter must preserve native
  eligibility, costs, failure and part callbacks without spoofing a player.
- Removal preserves item contents/radio presets and drops the original on the
  ground when inventory is full. Installation removes the carried item before
  probability/callback processing. Partial failure requires explicit identity
  reconciliation; return true is not sufficient success evidence.
- Jack, LugWrench, TirePump and NormalTire1 resolve enabled/nonobsolete. This is
  example item resolution, not universal tire compatibility or tool requirements.
  Tire callbacks change wheel removal state; inflation Lua has a sync TODO.
  Effective part definitions/recipes, native wheel physics and two-client pressure
  replication still require runtime verification.
- Inventory checker passes. No gameplay or production changes.

## Cooking inventory — 2026-09-19

- Added PREPARE_MEAL, COOK and BOIL_WATER: forty-eight first-pass records,
  thirteen proposed names remaining. No handler or acceptance claim added.
- Inspected installed ISAddItemInRecipe and ISToggleStoveAction. Ingredient
  action validation returns true on server/start and during action; completion
  mutates through EvolvedRecipe before later name/temperature/item-stat steps.
- Installed EvolvedRecipe accepts IsoGameCharacter but its private
  checkItemCanBeUse casts the actor to IsoPlayer at offset 9; public
  getItemsCanBeUse includes another cast at 218. Other mutation/spice/poison
  casts exist, some guarded; branch-specific audit still required. This excludes
  assuming safe whole-action reuse merely from the public signature.
- Bowl, Pot and Saucepan resolve enabled/nonobsolete; evolved recipes and
  accepted base/ingredient combinations still need effective registry capture.
  A stove toggle is not proof of available power, safe vessel or cooking.
  Native heat progression, fluid purification, interruption and replication
  remain explicit evidence gaps; no cooked/taint setters as fake completion.
- Inventory consistency checker passes. Production, main and Workshop unchanged.

## Trapping and digging inventory — 2026-09-19

- Added TRAP and DIG; fifty first-pass records and eleven proposed names remain.
  This does not close the compatibility inventory or enable either ability.
- Installed bait action reduces food before resolving the server trap and can
  return true when absent. Trap checking similarly returns true without a catch.
  Server trap state records actor username; retrieval has live-animal, corpse
  and food branches with owner XP and inventory sync. Catch creation precedes
  clearing the trap, requiring interruption/duplicate-reward checks.
- Six real trap item IDs resolve. Effective bait/animal definitions, placement,
  native catch simulation and headless identity/XP still need verification.
- Inspected DiggingUtil and ISDigStairsAction: UI is local-player/mouse based;
  queued action animates and updates item job state but contains no excavation
  mutation. Do not infer working digging from its class name. Farming furrows,
  graves, soil gathering and stairs need separate supported target semantics.
- Inventory checker and eight inventory tests pass. No gameplay, production,
  GitHub or Workshop changes.

## Fishing and foraging inventory — 2026-09-19

- Added FISH and FORAGE: fifty-two first-pass records, nine proposed names
  remaining. No physical acceptance or newly enabled commands.
- Native forage pickup requires a player-keyed discovered server record and
  distance check. It removes that record before item building/delivery, costs
  and zone depletion. NPC discovery identity, partial failure and exact effective
  item definitions remain required; arbitrary random loot is not an adapter.
- Fishing manager constructs client tension UI and uses input/player state.
  Server pickup obtains the native catch and inserts it at an animation-progress
  threshold, with ground-drop recovery on interruption. Pickup alone does not
  prove cast/reel/resource simulation supports IsoZombie; native catch association,
  XP, line/bait consumption and net-fishing path remain to audit.
- Base.FishingRod resolves enabled/nonobsolete. Inventory checker and eight
  tests pass; production, GitHub and Workshop remain unchanged.

## Base maintenance inventory — 2026-09-19

- Added INSPECT_BASE, MAINTAIN_BASE, FORTIFY_BASE, REPAIR_STRUCTURE and
  DISMANTLE. Fifty-seven first-pass records, four proposed names remain.
- Preserved distinction between current nearby-window FORTIFY and whole-base
  survey/planning. Report requires all ten specification fields and explicit
  unknown/unloaded coverage; maintenance selects verified child operations.
- Installed moveable repair consumes definition-driven materials before its
  success roll; action return true does not establish repaired health. Player
  number/cursor/halo dependencies and exact material definitions remain pending.
- Installed thumpable dismantling drops contents and randomized build-material
  salvage before removing object/stair group or restoring ground floor sprite.
  Partial-failure reconciliation, permissions, structural safety and exact tool
  tags/IDs require proof. Moveable scrapping is a separate path, not covered by
  merely inspecting thumpable dismantling.
- Inventory checker and eight tests pass. No gameplay, production or publishing
  changes; Milestone 0 remains incomplete.

## First-pass name coverage and gate audit — 2026-09-19

- Added PATROL, GUARD, DEFEND_BASE and experimental DRIVE. All sixty-one
  existing/proposed ability names now have first-pass records. Empty remaining
  name lists do not mean Section 31 or Milestone 0 is complete.
- Rechecked Defense: automatic defense requires the online owner as origin;
  explicit ATTACK returns to FOLLOW. Neither supplies offline guard or base
  patrol semantics. Proposed policies require bounded server-generated points,
  no Qwen coordinates, allowed loaded areas and return-after-combat behavior.
- Installed BaseVehicle signatures expose generic driver getter and several
  control members, but do not prove zombie driver support, physics input or
  network ownership. DRIVE remains a separate experimental gate.
- Section 31.9 audit: artifacts exist, but capability field formats are not yet
  normalized; some signatures, target classes, documentation URLs, permissions,
  replication/reconciliation, version links and test IDs are missing or only
  prose. Effective evolved/fixing/vehicle/forage/crop definitions remain pending.
  Source-audit unknowns and physical/multiplayer evidence are still substantial.
- Next: normalize required evidence fields and implement a separate strict
  inventory-completion audit that reports these gaps without weakening the
  current conservative no-completion checks. Then close runtime registry and
  actor compatibility gaps before Milestone 1. Do not enable proposed abilities
  merely because name coverage is now complete.

## Structured evidence coverage audit — 2026-09-19

- Added read-only `python -m tools.check_goblin_inventory --evidence-gaps`.
  Existing consistency validation runs first. Output explicitly never certifies
  completion, even with every field populated. No gameplay code changed.
- Current normalized-field gaps across 61 records: semantic arguments 18,
  target class 16, native API 3, documentation URL 61, item/recipe resolution 39,
  permissions 38, completion requirements 3, replication/save 43,
  reconciliation 61, verified versions 60, test IDs 61, MP evidence 61.
  These are structured-field gaps, not claims that all corresponding evidence
  is absent elsewhere in prose or earlier differently named fields. Review and
  normalize existing evidence before collecting it again; never fill by inference.
- Four added tests verify missing evidence, empty/scalar rejection, no mutation
  and that even filled claims do not certify completion. All 12 inventory tests
  pass. The tool is coverage reporting, not the final Section 31 acceptance gate.

## Craft evidence normalization — 2026-09-19

- Removed stale CRAFT statements that loaded recipe export was pending. Re-read
  actual Base.SawLogs record: one Log, retained saw-tag item (Saw/GardenSaw/
  CrudeSaw), three Plank outputs; compatibility remains UNKNOWN, not approved.
- Normalized permission, replication/reconciliation and test-reference fields;
  linked captured build/Storm provenance with explicit source/catalog-only scope.
  Retrieved official CraftRecipeData documentation as discovery reference only.
- Re-ran three named crafting boundary tests: all pass, still mocked-engine
  tests rather than native crafting or multiplayer acceptance. Inventory
  consistency check passes. No gameplay or production change.

## Supplemental registry collection preparation — 2026-09-19

- Verified installed ScriptManager getters for evolved recipes and fixings,
  plus BaseScriptObject.getScriptObjectFullType. These are separate registries
  from the existing CraftRecipe export.
- Added RuntimeSupplementalCatalog read-only collector: bounded definition
  enumeration, nonblank full identities, exact getter identity round-trips,
  duplicate rejection and deterministic immutable records. No item spawning,
  actor calls, callbacks or recipe execution.
- Collector compiles against the captured-matching 42.20.4 game JAR with JDK25.
  It is deliberately not yet wired into the startup export: loaded-registry
  execution, tests, definition detail extraction and fingerprint integration
  are next. Compilation does not establish that getters round-trip in runtime.
  Existing export files remain unchanged; no production writes.

## Supplemental collector boundary tests — 2026-09-19

- Extracted the same identity-validation path used by both installed registry
  collectors into a testable generic method; no game API mocked as proof of
  runtime compatibility. Added RuntimeSupplementalCatalogTest.
- Twelve Java checks pass: deterministic sort, obsolete preservation, immutable
  results, missing/null/blank definitions, duplicate IDs, equal-but-not-identical
  lookup rejection, absent lookup, size bound and legitimate empty registry.
- Compiled and ran against matching game JAR with JDK25. Loaded runtime
  enumeration and exporter integration remain pending; no new catalog output
  or gameplay/production mutation.

## Supplemental exporter integration — 2026-09-19

- Connected evolved/fixing identity collection to opt-in catalog collection.
  Fingerprint embeds supplemental_catalog with identity-only scope and UNKNOWN
  NPC compatibility, plus its own canonical SHA256. Existing item/recipe content
  hash contract and three-file atomic replacement scheme remain unchanged.
- Initial compile exposed checked IOException propagation from hashing; fixed
  fingerprintJson signature and recompiled successfully. Thirteen exporter
  checks and twelve supplemental collector checks pass. Windows filesystem did
  not support existing symlink test; do not count that case as passed.
- Next add Python validation for supplemental hash/identities, rebuild only the
  disposable helper, run loaded registry export and reconcile the explicit helper
  overlay. Current checked-in catalogs still precede this integration. No live
  supplemental export claimed and no production changes.

## Supplemental Python validation — 2026-09-19

- Added independent supplemental identity/hash validation to check_pz_catalog.
  Present extensions are always checked; --require-supplemental rejects older
  exports without the extension. Legacy artifacts remain readable by default.
- Rejects half-present extension, invalid schema/scope, unsupported compatibility
  claims, invalid identity kinds/types, duplicates and tampering. Canonical field
  order matches the Java serializer and does not depend on JSON input key order.
- Twenty-two catalog tests pass, including four supplemental test methods.
  Existing strict runtime validation still passes for 5397 items / 1118 recipes.
  These existing files do not yet contain a supplemental export. Next remains
  disposable helper rebuild/run and exact overlay reconciliation; no production
  or gameplay changes.

## Verified supplemental runtime export — 2026-09-19

- Rebuilt only disposable helper (SHA256
  692dbd38dd6171c6744f27cf1021555be8da369d615ca12fbbb5905fc57b890b).
  Loopback catalog server exported at 2026-09-19T19:15:10.912341900Z:
  5397 items, 1118 craft recipes, 63 evolved recipes, 72 fixing definitions.
- Independent strict runtime + supplemental validation passed. Supplemental
  canonical SHA256 is 0aaa4198befe2083c19fc893d895c6b47ee9f58b8f55faec6c4df99a3ef34b70.
  Effective candidate mod fingerprint is
  695c3eccf7fbb61baf7d2cf6742e21bd283ed5ce9cfd8a3f02a9bbcbe87bda2d.
- Reconciliation verified all 68 selected mods and vanilla Lua/scripts against
  captured content, allowing only explicit candidate helper difference. Updated
  generated reference catalogs/reconciliation after preserving prior files in
  disposable runtime backup. Existing inventory consistency check passes.
- Test server console quit completed; session 63610 exited zero, shutdown log
  finished and loopback test ports are no longer bound. No production restart.
- Supplemental identities now have loaded-runtime evidence; definition details,
  native actor compatibility and physical MP behavior remain unproven. Next
  inspect/export resolved evolved ingredients and fixing requirements without
  executing callbacks or creating inventory instances.

## Native fixing material identity audit — 2026-09-19

- Confirmed installed Fixing.Fixer exposes name, numberOfUse and skill list.
  Native PredicateRequired excludes the broken item, compares fixer name to
  InventoryItem.getFullType at bytecode 26-40, then counts actual uses. No
  implicit Base prefix occurs in this material-selection path.
- GoblinVehicles supply selection lines 86-87 adds Base to unqualified names.
  Fetched supply therefore is not proof that native costs accept the item.
  This is a source-level mismatch risk, not an observed live failure. No fix
  enabled before inventory gate.
- Updated REPAIR_VEHICLE: 72 fixing IDs now have loaded-runtime evidence;
  per-fixer quantities, skills/global requirements still need export and audit.

## Existing/proposed command validation correction — 2026-09-19

- Found validator regression exposed by complete first-pass name coverage:
  existing chat tasks were checked against all catalog IDs, allowing proposed
  records once inventoried. Prior test covered only not-yet-cataloged proposals.
- Added failing regression proving a cataloged proposed FUTURE task was accepted;
  then restricted existing command mappings to records with origin=existing (or
  explicitly remaining existing inventory). Real command inventory still passes.
- Thirty-five inventory/catalog tests pass after correction. This fixes evidence
  validation only, not gameplay dispatcher behavior; proposed commands remain
  unimplemented. No production or publication changes.

## Fixer namespace risk narrowed — 2026-09-19

- Installed Fixing.Load constructs Fixer from parsed text; Fixer constructor
  stores name unchanged and getter returns it directly. No namespace rewriting
  in these inspected paths. Skill getters expose actual skill name/level.
- Bounded captured vanilla script scan found 53 Fixer/GlobalItem declarations
  across two files, all fully qualified; every declared ID exists in loaded
  item catalog. Thus the fallback mismatch is not demonstrated for those vanilla
  declarations. Do not present it as the cause of current repair failure.
- Effective mod-added requirements remain pending loaded detail export. Updated
  REPAIR_VEHICLE evidence to distinguish potential malformed/mod-data risk from
  the verified vanilla result; no gameplay changes.

## Fixing requirement export implementation — 2026-09-19

- Extended opt-in exporter with fixing_details and separate SHA256: target
  items, alternative fixers, global fixer, actual use counts, skill names/levels
  and condition modifier. Item references preserve declared and exact lookup
  result separately; null resolution remains explicit, no namespace guessing.
- Collection reads loaded definitions only, bounds nested lists, rejects null
  definitions/blank requirements and nonfinite modifiers; no item factory,
  actor execution or gameplay callbacks. No production helper updated.
- Matching-JAR compile passed; exporter now passes 17 checks including unresolved
  names, quantities, skills and absent global fixer serialization. Existing
  Windows symlink check remains unavailable, not passed.
- Python detail validation and disposable runtime export still pending. Current
  reference fingerprints contain earlier identity-only supplemental evidence,
  not these newly implemented material details.

## Fixing detail validation — 2026-09-19

- Added optional/required independent fixing detail validation: exact coverage
  of supplemental fixing identities, item lookup/obsolete consistency, material
  quantities/skills types, bounded nested lists, finite modifier and canonical hash.
  Unresolved names stay explicitly null and do not certify compatibility.
- Modifier is exported as native Java float text to avoid cross-language float
  formatting changing hashes. No generated reference file changed yet.
- Twenty-six catalog tests pass, including cost-tampering, omitted definitions,
  unknown material IDs, unresolved-name handling and nonmutation. Existing runtime
  plus supplemental validation passes. Fresh compiled/disposable detail export
  remains next; no production or gameplay changes.

## Loaded fixing requirements verified — 2026-09-19

- Disposable export at 2026-09-19T19:26:17.712498100Z includes all 72 fixing
  definitions and 513 target/material references. Every reference resolves to
  the exact declared full type; none unresolved or namespace-remapped. This rules
  out the suspected Base-prefix mismatch for this captured effective registry.
- Detail hash eb52f091d1de6d7b9b823d06d1c4d09f731ffc4d9a06800099737a06466a8c1b.
  Disposable helper hash b4b57974334b065d153d6f372d85c93aabddc75292fdd8c35e719b00c343c4dc.
  Strict runtime/supplemental/fixing validation passed; 39 catalog/inventory
  Python tests passed during startup.
- Reconciliation again verified 68 mods plus vanilla source trees with only the
  explicit helper overlay. Preserved prior reference files in temporary backup
  and refreshed generated catalogs/reconciliation. Console quit session 89923
  exited zero; production untouched.
- Real repair movement, material consumption, chance/condition, nested actor
  compatibility and multiplayer replication remain unverified; resolved costs
  are not physical completion. Evolved-recipe details remain the next registry gap.

## Evolved-recipe detail export implementation — 2026-09-19

- Inspected native ItemRecipe getters/fields and EvolvedRecipe possible-item
  getter (copies definition map values without executing ingredient eligibility).
- Added read-only detail collection/export: base/result references, max items,
  minimum water as native float text, cookable flag and ingredient references
  with nullable use/cooked fields. Preserve absent fields, reject duplicates and
  excessive lists; no player-oriented eligibility or recipe execution.
- Embedded evolved_details with separate hash and UNKNOWN NPC compatibility.
  Matching-JAR compile and 20 exporter checks pass; Windows symlink case remains
  unavailable. Independent validation and disposable runtime export are next;
  current reference files do not claim evolved detail evidence yet.

## Evolved detail validation — 2026-09-19

- Added independent evolved_details validation and --require-evolved-details.
  Checks exact supplemental registry coverage, item resolution/obsolete status,
  duplicate ingredients, bounded lists, nullable use/cooked values, finite water
  text and canonical hash. Present extensions always validate; older exports are
  allowed unless explicitly requiring the new details.
- Thirty catalog tests pass including nullable fields, no mutation, tampered
  water requirement, duplicated ingredient and missing recipe coverage. Existing
  runtime/supplemental/fixing artifacts still pass strict checks. New evolved
  detail export has not run yet; no production or gameplay changes.

## Loaded evolved requirements verified — 2026-09-19

- Disposable export at 2026-09-19T19:33:03.064537900Z captured all 63 evolved
  recipes and 7007 base/result/ingredient references; every reference resolves
  exactly, no missing IDs or namespace substitutions. Native limits/water/use/
  cooked flags now have runtime definition evidence, not actor acceptance.
- Detail SHA256 ca7aeddd5496d3f7c9adbd7c0020991ac4ba85e1ec01363a895c9794ec1902f9;
  helper SHA256 c20366779955b66487d745601f1b69ef65b79462ccf18b0741d334c0d85b76c2.
  Strict runtime/supplemental/fixing/evolved validation passed and 43 focused
  Python tests passed. Reconciled all 68 mods and vanilla sources with only
  explicit helper overlay. Backed up prior artifacts and refreshed references.
- Console quit session 24926 exited zero. Production unchanged. Meal actor
  compatibility, actual costs/heat/movement and replication remain missing;
  this closes definition lookup gaps, not the physical capability gate.

## Inventory gate follow-through — 2026-09-19

- Removed contradictory pending-export text from repair/material and meal
  records now covered by verified runtime detail exports. Inventory check passes.
- Re-read Section 31 source precedence and identified next uncollected effective
  data: farming_vegetableconf.props, vehicle part install/uninstall tables and
  forage/trap definitions. These are not replaced by craft/evolved/fixing lists.
- Inspected installed farming configuration: seedTypes may be explicit or absent;
  seedName can differ from planting seeds (BarleySheaf vs BarleySeed), and
  seasonRecipe is a namespaced knowledge string. Capture fields faithfully from
  loaded Lua tables; do not infer planting IDs from seedName or treat knowledge
  strings as CraftRecipe IDs. Effective mod-overridden values still need export.
- Remaining M0 work includes those runtime mappings, normalized required source/
  authority/permission/evidence fields and actor compatibility classification.
  Real ability acceptance remains separate; no milestone promoted or gameplay
  feature enabled by this cleanup. Production unchanged.

## Loaded crop collector preparation — 2026-09-19

- Added RuntimeCropCatalog reading farming_vegetableconf.props via Kahlua rawget
  and table iteration only. No Lua calls/metamethod evaluation or inventory/world
  mutation. Captures crop key, seedName, vegetableName, produceExtra, seasonRecipe
  and seedTypes separately, preserving absent versus empty seed lists.
- Bounded crop/seed counts; rejects wrong types, sparse/invalid indices rather
  than silently dropping entries. Deterministic immutable results.
- Compiled against matching game JAR and ran seven checks with actual Kahlua
  tables: absent/empty/explicit seed distinctions, unchanged source fields and
  malformed seed rejection. Loaded runtime export, item resolution and export
  validation are still pending; collector not yet connected to exporter.

## Crop export integration and validation — 2026-09-19

- Connected bounded crop collector to opt-in export with crop_details and
  separate hash. Fields retain native names/absence; no recipe execution.
- Independent validator checks structure, duplicates, canonical hash and exact
  item references; unresolved names are returned explicitly, not guessed.
  season_recipe is intentionally not resolved as item or CraftRecipe. Added
  --require-crop-details for new runtime captures.
- Thirty-four catalog tests pass; matching-JAR exporter compilation passes.
  Four new crop tests cover knowledge separation, unresolved seeds, absent/empty
  lists and tampered/duplicate records. Loaded crop export remains next; no
  new crop runtime evidence or production/gameplay change yet.

## Loaded crop definitions verified — 2026-09-19

- Disposable export 2026-09-19T19:40:49.693388800Z captured 55 effective crops
  with zero unresolved item references. Strict runtime plus supplemental,
  fixing, evolved and crop checks passed. Crop hash:
  22f7adee3290e7dc4db9ebc293960f099ebb64492b3b7e1d0e4f2e4cd4a35c37.
- Helper hash f2a0691a65b357241a01b9c69925e210bddb00c3dd10deead5fb2a47c72de92c.
  Reconciliation verified 68 selected mods and vanilla source trees, allowing
  only candidate helper overlay. Preserved prior artifacts and updated references.
- Test session 45869 exited zero after console quit. Production untouched.
  Crop lookup evidence is now available; native planting/harvest costs, actor
  support, season knowledge and physical MP outcomes remain unverified.

## Farming catalog reconciliation — 2026-09-19

- Updated FARM inventory to reference the verified 55 loaded crops rather than
  the superseded single-crop example. No gameplay implementation changed.
- Installed CFarming_Interact.lua and ISFarmingMenu.lua use seedTypes or
  seedName fallback, matching Goblin. ISSeedActionNew.complete consumes one
  seed item; Goblin's one-item quantity is not a demonstrated defect.
- Inventory removal replication, plant owner assignment, eligibility and
  partial-failure handling remain separate unresolved compatibility checks.
- Strict runtime catalog validation and 47 focused Python tests passed.
  Inventory validator must be invoked as a module from the repository root;
  direct script invocation failed its tools package import.

## Native planting eligibility evidence — 2026-09-19

- ISFarmingMenu.lua:25 predicateGoodSeed rejects rotten/cooked/burnt Food,
  nonfresh cuttings and insufficient remaining hunger portions. GoblinFarming
  line 108 checks only the accepted full type, including food planting inputs.
- Loaded Potatoes.seed_types includes Base.Potato. A Lupa diagnostic loaded
  the exact installed predicate and real Goblin adapter with the existing job
  fixtures: native predicate rejected a mocked rotten Food potato; Goblin
  consumed it and seeded the fixture plot. This establishes an adapter-level
  eligibility omission, not real actor execution or multiplayer verification.
- ISFarmingMenu.canPlow knowledge/Farming-level branch controls tooltip
  disclosure, not planting permission. SPlantGlobalObject.seed applies season
  curse/yield effects itself. Do not introduce a knowledge/season prohibition
  that vanilla does not enforce.
- Minimal later correction: native-equivalent food eligibility at supply
  selection and immediately before reservation, with freshness/portion tests.
  No gameplay correction applied before the inventory gate.

## Chat inventory executable dispatch checks — 2026-09-19

- Added tests/test_goblin_command_inventory.py executing the real Lua command
  module through its registered OnClientCommand callback. Downstream Brain,
  Spawner, authorization and event registration are explicitly spies.
- Every catalogued existing spelling/alias reaches the declared handler and
  task; proposed commands do not dispatch. Admin despawn, malformed transport,
  disabled mod, raw API/code strings and invalid subcommands are checked.
- Injected foreign owner/npc/task/coordinates do not change authenticated horse
  ownership; follow payload is rebuilt with horse rather than trusting extras.
- Six new tests plus thirteen inventory tests pass. git diff --check passed
  with existing line-ending warnings. No gameplay/production edits.
- This closes the narrow command-map reachability check, not downstream task
  correctness, real transport security, Qwen dispatch or physical MP acceptance.

## Qwen response capability and mode gaps — 2026-09-19

- Traced propose_chat -> IntentValidator -> SafetyController -> NpcBodyDriver
  -> GoblinBridge normalization -> Brain. Generation schema is narrower than
  independent response validation; no assumption that llama.cpp honors grammar.
- Mocked FLEE/ROAM passes propose_chat despite being absent from its schema.
  GoblinBridge explicitly normalizes FLEE/RETREAT to FOLLOW: do not describe this
  as an implemented escape behavior or mistake it for a missing handler.
- Mocked PARTY/FOLLOW passes with SAFE context. Controller intentionally allows
  model/server mode differences, so model-declared mode is not authoritative
  capability enforcement. Authoritative mode and drift policy need reconciliation.
- Added two expected-failure acceptance tests documenting both omissions, not
  endorsing current behavior. Qwen/validator run: 16 tests, 14 passes and two
  expected failures. Neither gap fixed; no .76 traffic or production mutation.

## Enabled toolkit and recipe identifier checks — 2026-09-19

- Added tests/test_goblin_runtime_identifiers.py: loads real GoblinTools and
  GoblinCrafting through job fixtures and reads the captured runtime catalogs.
- All 19 current built-in toolkit IDs resolve enabled/nonobsolete with exact
  runtime lookup evidence. All 1,118 captured recipe IDs survive the real Lua
  resolver's exact-ID route against registry-derived stand-ins. This is not
  execution of recipes and does not change UNKNOWN NPC compatibility.
- Synthetic duplicate display names, missing IDs, invalid lengths/control
  characters are rejected. One hundred unknown non-tool-slot item requests
  produce no inventory AddItem calls; scheduler retry behavior is not proven.
- Captured recipe short names have zero duplicates, so module-loss risk is not
  established as an active collision in this snapshot.
- Four focused tests pass. Initial run also collected 24 imported fixture-class
  tests; changed import to module form to avoid redundant discovery. No gameplay
  edits or production changes.

## Vehicle definition collector preparation — 2026-09-19

- Added RuntimeVehicleCatalog for bounded, deterministic reads of loaded
  ScriptManager vehicle definitions. Exact vehicle/part identity round-trips,
  duplicate rejection, raw ordered item types, mechanic/key flags, callback
  names and table names; immutable snapshots. Does not spawn vehicles or invoke
  callbacks, and does not claim the named tables have been fully exported.
- Matching-JAR bytecode confirms VehiclePart.getItemType directly returns its
  scriptPart.itemType. No namespace guessing or item-instance construction is
  needed to capture that definition list. Table contents and callback/actor
  compatibility still require separate inventory work.
- Compiled against the captured-version game JAR; eight Java checks passed
  using actual VehicleScript.Part objects (null/empty distinction, copy
  isolation, flags, callback preservation, immutability, invalid entries).
- Not connected to exporter yet; no loaded vehicle counts or resolved item
  claims. Next: hashed export/independent validation and disposable capture.

## Loaded vehicle definitions verified — 2026-09-19

- Integrated vehicle_details and separate SHA-256 into opt-in export. Added
  independent schema/hash/reference validation and --require-vehicle-details.
  Null versus empty item lists preserved; callbacks/table names not treated as
  item IDs. Four new validator tests; all 38 catalog tests passed across two runs.
- Disposable capture 2026-09-19T20:00:13.125893800Z: 241 vehicle definitions,
  7,992 parts, zero unresolved item references. Vehicle detail SHA-256:
  5ad07422ff087cf279143aa5aa62a694542276e378e9dc641638608b5e925389.
- Reconciliation verified 68 selected mods and both vanilla trees with only
  candidate helper overlay. Backed up prior references and promoted captured
  artifacts; strict validator and capability inventory consistency passed.
- Server session 7772 exited zero after quit; reconciliation 75935 exited zero.
  No production activity. Vehicle table contents, callback actor compatibility
  and real multiplayer service operations remain unverified.

## Nested vehicle requirements capture preparation — 2026-09-19

- Loaded vehicle catalog has 42 distinct lifecycle callback-role/name pairs,
  6,870 install tables and 6,870 uninstall tables. Install/test callbacks live
  inside these tables, not the lifecycle luaFunctions map already exported.
- Installed generated vehicle template_battery.txt and template_brake.txt
  show nested item requirements (tags/type, count, keep/equip), skills, recipe
  knowledge, door/part prerequisites and test names. Raw tables must be captured
  rather than inferring these requirements from accepted replacement items.
- Added RuntimeDefinitionTable: raw Kahlua iteration into immutable typed nodes,
  preserving numeric versus string keys and scalar types. Numeric values retain
  Double.toString text for deterministic cross-language hashing. Bounded depth,
  total nodes and text; rejects cycles, nonfinite numbers and unsupported values
  without invoking Lua functions. Shared noncyclic subtables remain valid.
- Matching-JAR compilation and ten actual-Kahlua-table checks passed. Collector
  not yet integrated with vehicle export; existing runtime artifacts unchanged.

## Vehicle requirement tables captured — 2026-09-19

- Vehicle schema v2 embeds typed nested tables with canonical hashing. Python
  validates structure, bounds, scalar types, duplicate typed keys and exact
  table-name coverage. --require-vehicle-tables rejects absent/v1 captures.
- Forty-two catalog tests pass; Java table/vehicle tests pass 18 checks; complete
  helper compiles against matching installed JAR and captured Storm.
- Disposable capture 2026-09-19T20:07:22.370516300Z exported 14,604 tables across
  241 vehicles/7,992 parts. Detail hash:
  f874c73a24cc105273d3be9e86368a9d1e192beecdd26ea985ab7a5157e8fd86.
- Loaded install tests: 6,869 Vehicles.InstallTest.Default. Uninstall tests:
  6,653 Vehicles.UninstallTest.Default and 216 Vehicles.UninstallTest.Battery.
  Base.ModernCar_Martin/HoodOrnament has install/uninstall tables without test
  fields; absence is preserved, not replaced with an inferred default.
- Strict validation and 68-mod/vanilla-tree reconciliation passed; prior
  references backed up before replacement. Server 75688 and reconciliation
  64867 exited zero. Production unchanged. Required item/tag/skill/recipe
  semantics and callback actor compatibility remain to be classified.

## Vehicle service requirement resolution — 2026-09-19

- Added tools/audit_vehicle_requirements.py (module invocation) which first
  validates the hashed v2 capture, then resolves installed enabled/nonobsolete
  exact items and tag alternatives. Three focused tests plus eight vehicle
  schema tests passed; no game or model calls.
- Across 13,740 install/uninstall tables: Base.Jack resolves in 5,264 declared
  requirements. base:lugwrench resolves to LugWrench/TireIron; base:screwdriver
  to Handiknife/Multitool/Screwdriver/Screwdriver_Improvised/Screwdriver_Old;
  base:wrench to Ratchet/Wrench (all Base namespace). Zero missing referenced
  requireInstalled/requireUninstalled/door part IDs in this capture.
- Knowledge names Advanced Mechanics, Basic Mechanics and Intermediate
  Mechanics remain knowledge references, not falsely mapped to CraftRecipe.
- Installed Vehicles.InstallTest.Default and UninstallTest.Default call
  VehicleUtils.getItems(chr:getPlayerNum()). getContainers then dereferences
  getPlayerInventory/getPlayerLoot UI inventory panes. Entire native test path
  is not a headless managed-actor adapter. Battery uninstall delegates to that
  path before checking engine state. Workshop source scan found no direct
  function redefinitions by these names; dynamic patching is not ruled out.
- Native testItems checks type OR tag presence, with its count branch empty;
  testPerks calls in the default tests are commented out. Preserve these facts
  separately from declared count/skills and later completion consumption/risk.
- Minimal future adapter must use Goblin's actual authorized inventory and
  native-equivalent prerequisites without UI/fake-player emulation. Tools alone
  do not establish an executable vehicle-service capability. Production unchanged.

## Trapping/foraging collector preparation — 2026-09-19

- Installed TrapDefinition.lua defines Traps and TrapAnimals, including bait,
  trap-type, destroyed-item, animal type/breed and zone data. forageSystem.init
  builds itemDefs around mod hooks, so static defaultDefinitions is not an
  effective runtime catalog and player discovery state is a separate system.
- Added RuntimeSurvivalCatalog reading initialized Traps/TrapAnimals and
  forageSystem.itemDefs. Refuses uninitialized foraging instead of calling init.
  Forage key/type roundtrip, bounded records/fields, selected prerequisite,
  season/zone/count fields and explicit unexported-field names. spawnFuncs and
  other omitted values are never executed or implied to be inspected.
- Extended typed snapshot helper to accept individual definition values.
  Matching-JAR compilation and seven Kahlua checks passed, including refusal
  without mutation, key/type mismatch and opaque callback preservation.
- Export integration, independent validation and loaded capture remain pending;
  no new trapping/foraging runtime counts or ability claims. Production untouched.

## Loaded survival definitions verified — 2026-09-19

- Integrated survival_details with separate hash; independent validator checks
  typed tables, exact forage key/type match, explicit omissions, item references
  and capture integrity. Added --require-survival-details and four tests;
  30 focused catalog tests passed, complete helper compilation succeeded.
- Disposable capture 2026-09-19T20:16:38.993853400Z: six trap definitions, six
  trap-animal definitions and 1,679 forage definitions, zero unresolved item
  references in checked fields. Native foraging initialized before export.
  Survival hash c284a2371eb681359192fc2b3c3bf5ec03f6c222e251130d91f0be693b774f03.
- Reconciliation matched 68 selected mods and both vanilla trees with only the
  candidate helper overlay. Backed up/replaced reference artifacts; all strict
  catalog flags and capability consistency checks passed. Server 5853 and
  reconciliation 56068 exited zero. No production mutation.
- Animal/breed/zone/knowledge/tag semantics and omitted forage spawn callbacks
  remain separate compatibility work. Resolved item definitions do not prove
  collection, bait consumption, catch creation, actor support or MP replication.

## Effective forage prerequisite classification — 2026-09-19

- All 1,679 captured definitions explicitly include itemTags, traits, recipes
  and perks. No item-tag or trait prerequisites are populated in this snapshot;
  all use PlantScavenging. Do not invent a current missing-tool blocker.
- Six medicinal definitions require Herbalist: BlackSage, Comfrey, CommonMallow,
  Ginseng, Plantain and WildGarlic2 (Base namespace). Installed character trait
  definitions grant this knowledge string; it is not a CraftRecipe mapping.
- Native hasRequiredItems requires every listed tag on unbroken inventory
  items; trait/recipe helpers require every listed prerequisite; perk levels
  are averaged and rounded upward. Discovery and pickup remain different,
  player-keyed paths, not made compatible merely by these generic helpers.
- Updated FORAGE inventory's obsolete pending-definition text with runtime
  evidence and source references. Inventory consistency and four survival
  validator tests pass. No gameplay change or production activity.

## Effective trapping reference classification — 2026-09-19

- Added tools/audit_trap_requirements.py and three focused tests. It validates
  the hashed survival capture before separating trap, bait, destroyed-item and
  declared catch roles; enabled/nonobsolete status is required, not mere catalog
  membership. Unknown trap references stay findings rather than guessed IDs.
- Loaded result: six trap IDs, 37 unique bait IDs, five declared dead-catch item
  IDs and all destroyed-item references resolve. All animal trap references
  point to captured traps. Alive animal type/breed strings are kept non-item.
- ISAddBaitAction.complete mutates the bait's food values before looking up the
  trap, then may return true even when the trap disappeared. STrapGlobalObject
  addBait calls player:getUsername. Catch retrieval can construct IsoAnimal,
  use owner username/XP, force heavy-item drops, add/sync inventory and emit the
  animal pickup packet before clearing trap state. These are compatibility and
  transaction boundaries, not proof that a generic IsoZombie path works.
- Updated TRAP inventory's obsolete pending-definition text. Three audit tests,
  inventory consistency and existing catalog checks pass. No handler/gameplay
  or production change.

## Fishing collector preparation — 2026-09-19

- Installed fishing_properties.lua defines effective lure categories/index,
  fish configs and lure coefficients, trash, line, hook, rods/break replacements,
  fish-net output lists. Static Base.FishingRod resolution was insufficient.
- Added RuntimeFishingCatalog selecting nine definition tables from loaded
  Fishing without touching its functions or creating items. It refuses capture
  until the OnServerStarted lure All index is populated, rather than exporting
  a timing-dependent empty registry. Typed snapshots remain bounded/immutable.
- Matching-JAR compilation and six Kahlua checks passed: uninitialized refusal,
  selected field coverage, snapshot isolation/immutability and wrong-type
  rejection. Export integration/validation and loaded capture remain pending.
- FishingRod:new is player-indexed (username/player number, perks, hands and
  joypad state); updateLine is client input/tension logic. Definition resolution
  will not by itself make this manager an IsoZombie-compatible server adapter.
  No gameplay or production changes.

## Loaded fishing definitions verified — 2026-09-19

- The first exact-copy export at Storm OnServerStarted failed closed because
  vanilla Fishing.IndexAllLures had not yet populated Fishing.lure.All. Moving
  only the opt-in exporter to Storm OnTick still produced no capture with the
  exact PauseEmpty=true/zero-player settings. The final hook uses
  OnTickEvenPaused plus a read-only lure-index readiness gate; it neither calls
  IndexAllLures nor mutates the registry. Hard exporter failures remain one-shot.
- Disposable capture 2026-09-19T20:39:00.693524100Z contains 21 fish definitions,
  41 effective lures, five trash entries, three line entries, five hook entries,
  two rods, two break replacements and six entries in each fish-net output list.
  Fishing detail hash:
  26f43d4e370ee70fa5d199c29e23880dbebfc9a7781f3f01c5e43a0e9b333d3f.
- Strict catalog validation passes with fishing required. Independent
  reconciliation matches 68 selected .03 mods and both captured vanilla source
  trees; the only permitted difference is the explicit candidate Goblin helper.
- Two raw vanilla item strings are not exact loaded IDs. Native
  InventoryItemFactory.getItem explicitly maps missing *Empty names by removing
  the suffix, so Base.WaterBottleEmpty operationally resolves to Base.WaterBottle.
  Base.WoodenStick has no installed definition or native rename fallback;
  Base.WoodenStick2 is only a candidate name and is not inferred as equivalent.
- Fishing remains incomplete. The rod/manager path is player-indexed,
  client-input-driven and online-ID keyed; catch pickup and fish-net paths depend
  on player inventory, XP and network behavior. No managed-IsoZombie gameplay or
  multiplayer claim was added, and production, GitHub and Workshop were untouched.

## Effective moveable definitions verified — 2026-09-19

- Added a read-only RuntimeMoveableCatalog for the initialized private
  ISMoveableDefinitions singleton. It captures tool, material, scrap, health,
  repair and floor-replacement tables without calling getInstance or any Lua
  callback. The bounded typed serializer now handles only the known native
  Perk userdata by its stable registry ID; arbitrary userdata still fails closed.
- Exact-copy disposable capture 2026-09-19T20:52:13.906230400Z contains eight
  tool groups, nine material-return groups, 36 scrap definitions and 19 repair
  definitions. The moveable detail SHA-256 is
  219b5f1171c7ed68cf85b7c43c4e65a926b51c66004479c9f78c0c4e1b4826c4.
- All 107 referenced item strings resolve to enabled installed definitions or
  explicit Tag.Rope/Tag.SewingNeedle alternatives. Five loaded legacy short
  strings resolve uniquely and catalog-backed: Crowbar, HuntingKnife,
  KitchenKnife, Scissors and SharpedStone map to the corresponding Base.* IDs.
  The raw loaded definitions are preserved; the validator reports the mapping
  rather than rewriting source evidence.
- Native thumpable dismantling separately requires unbroken base:saw and
  base:screwdriver items. The loaded alternatives are three saws and five
  screwdrivers recorded in the capability inventory. Live getBuildMaterials
  remains per object and is not converted into a fixed recipe.
- Strict validation and independent reconciliation pass for 68 selected mods
  plus both vanilla trees, with only the explicit candidate helper overlay.
  Prior reference artifacts were backed up before promotion. No production,
  GitHub or Workshop mutation occurred.
- REPAIR_STRUCTURE and DISMANTLE remain incomplete. Repair consumes parts before
  its random success roll and the moveable action uses player-number/UI lifecycle
  code; dismantling creates salvage before world removal and perform references
  ISInventoryPage. Neither full timed-action chain has run on a managed
  IsoZombie or passed two-client/save acceptance.

## Current-source two-client follow sample — 2026-09-23

- A disposable `goblin-local` server ran with server-side Storm and two ordinary
  no-Storm clients, `rejoinfang_74` and `trailfang_74`. Both joined with distinct
  named Goblins. This did not alter `.03`, GitHub, or Workshop.
- Raw source-bound snapshots are in local test logs:
  `C:\Users\tomgr\Zomboid\Logs\logs_2026-09-23\m1-open-terrain-active-20260923.json`
  and `C:\Users\tomgr\Zomboid\Logs\logs_2026-09-23\m1-second-player-active-20260923.json`.
  Both captures matched the staged Lua/JAR fingerprint before and after, with
  zero read errors. They are raw evidence, **not** Milestone 1 acceptance.
- Rejoinfang traversed 13.93 tiles while Rattlefang moved 12.80 tiles and
  finished 2.81 tiles from the owner. Trailfang independently traversed 13.00
  tiles while Gutterclaw moved 13.35 tiles and finished 1.36 tiles away.
  The observed routes used the ordinary client's `Walk to` cursor (including
  double-click), so this does not by itself prove the formal *running* gate.
- While two clients were up, the background client process exited twice
  without an obvious fatal line in the current `console.txt` or a matching
  Windows Application event. The foreground client continued. Treat sustained
  two-client stability and all other current-source live gates, especially
  closed-door crossing and ownership handoff, as unverified. The accepted
  follow implementation was not changed for this sample.
- After this capture, the opt-in client trace gained native player
  `isRunning()`/`isSprinting()` observations. Installed Build 42 vanilla Lua
  uses these methods in `ISSearchManager.lua` and `ISBaseIcon.lua`; the Walk To
  cursor instead starts `ISWalkToTimedAction`, which does not establish running.
  The extractor now reports observed running-distance separately and treats
  older traces without those fields as unknown, not running. Four focused
  tests pass. Because this instrumentation changes a source hash, the two raw
  captures above are historical to the current worktree and cannot by
  themselves certify a current-source live gate; recapture with the opt-in
  client flag and a genuinely running owner is required.

## Current-source run-state live check — 2026-09-23

- Re-staged the current worktree to a disposable `goblin-local` server with
  server-side Storm, then joined as `rejoinfang_74` using one ordinary no-Storm
  client. The opt-in native `isRunning()`/`isSprinting()` trace produced 1,732
  matched samples for Rattlefang. Its summary reports a 7.07-tile net owner
  displacement and 4.35-tile net Goblin displacement, with 735 moving Goblin
  steps. The server's separate 59-snapshot capture had zero read errors and
  matched the installed source fingerprint before and after.
- Every sampled native player run state was false; observed running distance
  was zero. The route was issued through the game's `Walk to` cursor, so this
  is positive evidence that the cursor route is **not** a running-follow test.
  Raw traces (rotated by the next client launch):
  `C:\Users\tomgr\Zomboid\Logs\logs_2026-09-23\m1-run-native-20260923.json`
  and `C:\Users\tomgr\Zomboid\Logs\logs_2026-09-23\m1-run-client-20260923.json`.
- A second isolated, no-Storm client (`trailfang_74`) connected and loaded the
  world, but its process exited immediately after the loading screen, before
  an in-world actor/Goblin capture. Its console ended at `game loading took 18
  seconds` without a fatal Lua line; no matching Windows Application event was
  found. This repeats the earlier second-client instability, so two-client
  replication and the formal running-follow gate remain open. No gameplay
  code was changed, and no production or published installation was touched.

The current-source Milestone 1 checker now requires native run/sprint states,
continuous owning-client positions and a final Goblin gap no greater than five
tiles for both running gates. The walking-only trace above fails those gates by
design; the dated schema-1 record remains historical, not current acceptance.

## Follow/idle stall investigation — 2026-09-23

- The disposable local server and ordinary client reproduced repeated
  `NAV_NATIVE_REPATH` calls against a stationary obstacle. An interrupted native
  Idle/Face state now gets one direct recovery, followed by the existing
  timeout/blacklist when no movement resumes; 129 focused Lua/work tests pass.
- After restaging and restarting locally, `rejoinfang_74` walked out of a
  fenced yard and across the road; the same Goblin followed to approximately
  four tiles. A second account, `trailfang_74`, joined with its own Goblin.
  The isolated second-client package was initially stale; it was then restaged
  to the current worktree and rejoined. Neither client uses Storm.
- This run also exposed a distinct autonomous-loot stall: rejoinfang's Goblin
  stayed at one coordinate while many different nearby work approaches became
  blocked. A cross-route 30-second physical-progress cutoff now ends that
  chore and backs off autonomous loot for 60 seconds before retrying. This
  subsequent change has **unit-test evidence only**; the running local pair
  has not yet reloaded it.
- Source-bound raw captures are in local test logs as
  `m1-current-repath-two-client-20260923.json` and
  `m1-current-repath-two-client-moving-20260923.json`. Both matched the staged
  server/client source before and after, with zero read errors, but their
  player samples remained stationary during the capture windows. These are
  diagnostic snapshots, **not** running-follow or Milestone 1 acceptance.
  The browser control reported new user input, so no further game-window
  interaction was attempted. `.03`, GitHub, and Workshop remain untouched.

## Follow/idle stall follow-up — 2026-09-23

- Reloaded the first autonomous-loot progress cutoff on the disposable local
  server and ordinary client. The live Goblin stopped making progress at
  `10796.47,10067.50`; after 30 seconds the server logged `LOOT_BLOCKED`,
  switched to FOLLOW, and the owning client physically moved him back to
  approximately `10791.43,10054.51` without a position write. After the
  60-second backoff, however, the new LOOT task restarted its patrol at
  waypoint 1 and eventually returned to the same blocked area. This was a
  partial recovery, not a complete freeze fix.
- The patrol cursor now survives autonomous LOOT/FOLLOW handoffs for the same
  stationary anchor. In the next live run, the blocked cycle used waypoints
  1–3, recovered to FOLLOW, and resumed at waypoint 4 rather than waypoint 1.
  That different route physically reached supplies: eight items were logged
  as collected and deposited at the player. This verifies the route-memory
  change in the local game, not merely in a fixture.
- Moving the player then exposed a separate FOLLOW limit across a long white
  fence. The owning client reported `NAV_BLOCKED task=FOLLOW` and
  `FOLLOW_DETOUR_UNAVAILABLE ... expanded=192`; Goblin remained across the
  fence. The local detour search was bounded to 12 tiles/192 nodes and only
  enabled when the Goblin-player gap was at most 18 tiles. The source now
  allows a 24-tile search/1,024 examined nodes, with a 32-tile activation
  bound and a 5-second failed-search cache. Long-fence and long-idle-gap
  fixture tests pass, but the exact fence route has **not yet passed a live
  retest**. The latest disposable local client is running on this build.
- One source-bound owning-client trace of the initial blocked-to-FOLLOW
  recovery contains 2,107 position samples over 219 seconds, 677 physical
  Goblin movement steps, and no native player running samples. It is a
  diagnostic trace, not a running-follow or Milestone 1 acceptance record:
  `C:\Users\tomgr\Zomboid\Logs\logs_2026-09-23\m1-client-stall-recovery-20260923.json`.
- The most recent live client then recorded native player running while Goblin
  followed. A whole-log extraction mixed two Goblin online IDs across a
  rejoin gap and showed an invalid 108-tile apparent step; it is **not**
  continuous-motion evidence. The extractor now supports filtering to one
  native online ID. The source-bound, single-incarnation `21834` trace has
  1,740 samples, 51.77 tiles of player movement while native run/sprint state
  was true, 23.26 tiles net Goblin movement, a maximum physical Goblin step
  of 0.48 tile, 119 ms maximum sampling interval, and a 3.26-tile final gap.
  This supports a running FOLLOW segment but does not cover the exact blocked
  fence route or replace the full two-client Milestone 1 checklist:
  `C:\Users\tomgr\Zomboid\Logs\logs_2026-09-23\m1-native-run-incarnation-21834-20260923.json`.
- A later local run (`2026-09-23_22-02_DebugLog.txt`, actor online ID 26904)
  recovered from a blocked FOLLOW approach but froze again. At 22:08:11.604,
  its trace identity changed from `goblin.primary.horse` to `online.26904` and
  remained unconfirmed for 3,738 samples. This proves the client stopped
  binding the actor to its roster; path recovery alone cannot fix that guard.
  Installed `PersistentOutfits.setFallenHat` bytecode sets/clears `0x8000` in
  `getPersistentOutfitID`, while the client had compared the entire value.
  The comparison now ignores that clothing-state bit while retaining the
  outfit, seed, and gender bits. Regression checks accept both hat states and
  reject different seeds. Local logs now record raw outfit IDs on a mismatch
  to distinguish this cause from any other identity loss. Live validation in
  `2026-09-23_23-35_DebugLog.txt` recorded actor 4509 changing outfit state
  from 14155917 to 14188685 (exactly 32768) at 23:37:17.611 while retaining
  `goblin.primary.horse`; the clothing-state identity correction is verified.
- That same run exposed a separate native path stall: at 23:38:25 and
  23:38:37 Goblin remained at 10980,9730 with `PathFindState`, a non-null
  Path2, and `should_move=true`. Installed bytecode shows that behavior
  `cancel()` only sets a flag, whereas `PathFindState.exit` cancels the queued
  request and resets finder progress. The bounded stuck retry now exits that
  state before submitting its replacement route. Added regression coverage
  checks exit-before-submit ordering; 168 focused Lua/work/client/transport
  checks pass. The restarted local run (`2026-09-23_23-42_DebugLog.txt`,
  actor 2378) exercised native repaths and resumed physical movement without
  a NAV_BLOCKED or identity rejection in the captured interval. The
  source-bound 131-second trace contains 1,251 samples, 303 moving steps,
  13.90 tiles net actor displacement and a maximum 0.47-tile step:
  `C:\Users\tomgr\Zomboid\Logs\logs_2026-09-23\m1-path-state-reset-2378.json`.
  This is a short, single-client recovery check, not proof that all recurring
  freezes are resolved or full Milestone 1 acceptance. Six extractor checks
  also pass after accepting the new optional outfit diagnostics.
- Longer observation contradicted a complete freeze fix: the same actor
  logged blocked FOLLOW at 23:47:16 and 23:47:28 with zero deferred movement.
  A diagnostic restart reproduced the curtain obstruction at 10979,9729:
  the native actor was colliding, had a WALK animation with nonzero deferred
  movement, but repeatedly targeted 10979,9726. Thus this work-route stall
  is physical navigation, not an unreceived command. Server chat records
  confirm CLOSE_CURTAINS and subsequent FOLLOW orders were accepted.
- Coordinate work goals now use the existing bounded loaded-edge detour
  search after native failure, with separate weak runtime cache and precise
  destination reachability (not FOLLOW's three-tile acceptance radius).
  The original world-operation target is unchanged. Native simulation
  ownership, collision checks and no-teleport behavior are preserved.
  Wall-route, sealed-route, job, transport and work checks: 201 pass.
  This candidate is staged locally; actual same-house work-detour acceptance
  is still pending. Production and published packages remain untouched.
- The local work-detour retest could not enter play: the first connection
  failed during startup, then a client-only retry was explicitly denied for
  horse's saved credentials (`2026-09-23_23-58_DebugLog.txt`). The account was
  not reset; the user was asked to connect through the game without sharing
  a password. While awaiting that, the work-detour endpoint handling was
  corrected for destinations that are not tile centres, preserving their
  exact final coordinates. All 201 focused checks pass, including bounded
  retries when no alternate loaded route exists. This final endpoint change
  is source-only and still needs staging/restart before live acceptance.
- 2026-09-24: staged the endpoint correction in the empty disposable server
  and isolated client cache, then connected the existing `trailfang_74`
  account without changing horse's credentials. One named Goblin spawned.
  A source-bound 204-second ordinary-client smoke trace recorded 1,972
  samples, 1,078 moving steps and a maximum 0.57-tile step; the server
  transitioned from FOLLOW to idle LOOT and patrol waypoints. No blocked
  route or work-detour event occurred, so this confirms movement on the new
  build but does **not** verify the wall-detour branch or running follow.
  Evidence: `C:\Users\tomgr\Zomboid-Goblin-Client2\Logs\work-detour-candidate-smoke-20260924.json`.
  The account remains in-world for continued local testing.
- Broader unittest discovery exposed three inventory-test failures: one
  synthetic verifier fixture lacked the current JAR/native-run fields, and
  two are caused by stale capability source-audit hashes (first reported:
  GoblinTransport.lua). The synthetic temporary fixture was updated and its
  targeted test passes; no real acceptance artifact was changed. The source
  audit still needs review, and full-suite success is not claimed.
- 2026-09-24 source-audit refresh: reviewed current transport preparation,
  keyless-start postconditions, unlock permissions/physical approach, native
  passenger transition changes, loot stall/transfer changes, and locomotion
  recovery. Refreshed seven stale source references across six capability
  records (four distinct files). All affected records remain incomplete;
  historical multiplayer observations were not promoted to current proof.
  Installed `IsoGridSquare` signatures were checked: the InventoryItem
  AddWorldInventoryItem overload returns InventoryItem, consistent with the
  exact-item delivery postcondition. No new live transfer claim is made.
  Inventory tests: 19 pass. Inventory consistency: 64 records pass with
  explicit proof gaps. Full discovery: 518 tests run successfully, with two
  pre-existing expected failures. The ordinary local client remains running;
  no NAV_BLOCKED or WORK_DETOUR event was recorded through 00:09:04, so the
  particular wall-detour branch still lacks live acceptance.
- Current-build transport smoke observation, 2026-09-24: while the user
  controlled `trailfang_74`, the local server accepted natural-chat unlock
  and start orders. For vehicle 254 it recorded `TRANSPORT_UNLOCK_RESULT`
  (seat 0, unlocked=true) at st=511318282, boarding at st=511330287,
  a native keyless attempt at st=511341982, and the observed engine-running
  postcondition at st=511343786. The ordinary client visibly showed Goblin
  aboard and the ignition conversation; runtime state independently retained
  riding=true and transport_active=true. This is one-client smoke evidence,
  not two-client lock/engine replication, reload, or wall-navigation proof.
  Transport source SHA-256: cc94ea28400fef3e854f258d3434298196f6f9000e91440201e9cedeb8812b3a.
  Source log: `C:\Users\tomgr\Zomboid\Logs\goblin-local-server.stdout.log`.
  No client controls were issued once the user's vehicle test was observed.
- Subsequent freeze diagnosis (2026-09-24 00:14:18 client log): online actor
  6499 had native PathFindState, a valid Path2, bMoving=true and bPathfind=true,
  but animation/action state `turnalerted` and deferred_length=0. Installed
  vanilla turnalerted transitions require ActiveAnimFinishing; Goblin's
  Bob_IdleRifle fallback does not emit it. GoblinGuard previously inspected
  only the native FSM. Added a simulator-only ActionContext recovery from
  exactly turnalerted to the group's idle state, preserving the current path.
  Remote actors, normal navigation, and fence/window contexts are unchanged.
  Regression covers ownership, path retention, unrelated contexts and missing
  API behavior. Full suite: 519 tests, two existing expected failures.
  Staged locally and restarted the disposable pair; live acceptance remains
  pending. This does not certify the wall-detour branch or multiplayer gates.
- Live correction to the preceding candidate: the 00:19 client run exposed
  `attempted index: getGroup of non-table: zombie.characters.action.ActionContext`.
  The public Java API is not Lua-exposed. Removed the entire direct-context
  recovery and its misleading mocked-API regression. Installed AnimLayer
  bytecode confirms onNonLoopedAnimFadeOut/onNonLoopedAnimFinished emit
  ActiveAnimFinishing; vanilla turnalerted Default.xml sets m_Looped=false.
  The Goblin fallback omitted that field. It now explicitly sets false and
  stops on exit, retaining Bob_IdleRifle and its Goblin-only condition.
  Added a packaged-XML contract regression plus a check against reintroducing
  the unsupported Lua context call. All 60 focused Lua tests pass. Restarted
  the disposable setup for this corrected candidate; no live pass yet.
- The corrected candidate loaded in the 00:23 client run (online actor6094).
  Client and server processes remain active; the user resumed vehicle control,
  so no further UI inputs were sent. Boarding succeeded at st=512237056.
  Through 00:24:27 there were no getGroup exceptions or NAV_BLOCKED events;
  movement at that point was vehicle travel, not on-foot recovery evidence.
  Added GoblinGuard and the turnalerted XML to current M1 source fingerprints
  (17 files plus JAR), preventing reuse of evidence from the broken fallback.
  All 33 acceptance/trace/inventory checks pass. No gate promoted to complete.
- User acceptance of the corrected animation/pathing build: "perfect, fixed"
  on 2026-09-24. The same local run recorded getting out at st=512286857,
  back on foot at st=512287756, and a successful defensive shotgun hit at
  st=512318063. No NAV_BLOCKED events appeared through that observation.
  The reported freeze is accepted; do not keep changing this movement baseline
  absent a new reproduction. This is not blanket completion of the wider V2
  specification or the separate two-client milestone gates.
- Current-source second-client attempt: ordinary no-Storm rejoinfang_74 client
  PID4688 connected and reached Click to Start, then terminated at 00:28:10.
  `hs_err_pid4688.log` identifies EXCEPTION_ACCESS_VIOLATION in glfw.dll+0x10fa1
  under Display.processMessages/RenderThread, outside the Java VM. No causal
  attribution to Goblin or UI automation is established. The first client and
  server remained live. Retrying the second client without window automation;
  this failed attempt does not establish a two-client gameplay pass.
- The retry entered play at approximately 00:30:46. Live exact-state and
  ordinary-client traces show rejoinfang_74 with online actor6215 and
  trailfang_74 with actor6094, exactly one Goblin per player, each controlled
  by its respective native client owner. The players are about 3,100 tiles
  apart, so this is spawn/separate-ownership evidence only, not mutual
  visibility, native handoff, or world-change replication. Source-bound raw
  capture: `C:\Users\tomgr\Zomboid\Logs\m1-two-client-spawn-20260924.json`.
  Requested an ordinary run/door/stair route from rejoinfang_74; no gameplay
  code changed and no production or publication action occurred.
- Current rejoinfang route observation: 39 exact-state snapshots captured
  without read errors, then 1,469 owning-client samples extracted for actor6215
  in `C:\Users\tomgr\Zomboid\Logs\m1-rejoinfang-route-client-20260924.json`.
  Player running distance was 80.27 tiles; Goblin finished about 2.93 tiles
  from the player. However, the maximum actor step was 33.83 tiles in a trace
  with at most 212ms between samples. This is not continuous no-teleport
  running-follow acceptance. Preserve the accepted gameplay baseline; do not
  promote the entire trace merely because the final follow distance is good.
  Closed-door and stairs are not proven by this position-only observation.
- Correlation established: the 33.829-tile client jump between timestamp
  1790224376630 and 1790224376732 matches server FOLLOW_REJOIN at
  st=512750309, owner=rejoinfang_74, distance=31.2. It is companion catch-up,
  not continuous native walking proof. No movement implementation was changed.
  The confirmed ActionContext Lua exposure limitation and native non-looped
  turnalerted lifecycle are now recorded in docs/PZ_REFERENCES.md.
