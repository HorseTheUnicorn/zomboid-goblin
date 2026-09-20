# Abilities V2 evidence ledger

## Gate: Milestone 0 runtime catalog and compatibility inventory complete

Section 31's non-mutating, exact-installed-runtime catalog and conservative
compatibility inventory closed on 2026-09-19. This closes only Milestone 0.
Milestone 1 implementation is now in a unit-tested candidate state: native
character-follow, stable nearby slots, radius-2 work staging, bounded stuck
recovery, temporary route blacklists, exact Build 42 path-next field handling,
and navigation telemetry are implemented. It is **not complete** until a live
local multiplayer run proves movement and replication. An installed method,
parsed definition, accepted command or
mock test is still not proof of physical execution or multiplayer replication.
Every capability remains `complete: false` until its own movement, material,
world-state, second-client and persistence acceptance evidence is recorded.

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
- Remaining Milestone 1 live gates are stairs and owner running through a
  building. Milestone 1 remains `complete: false`.

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
