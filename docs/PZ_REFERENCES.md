# Project Zomboid runtime evidence

Milestone 0's exact-runtime catalog and conservative compatibility inventory are
**complete** as of 2026-09-19. See [the ledger](ABILITIES_V2_PROGRESS.md).
Nothing in this document enables a new command or establishes engine acceptance.
The current inventory contains 64 abilities (27 existing, 37 proposed), with no
current-worktree capability marked complete. Historical live acceptance is kept
separate from proof for the changed source now in this worktree.

The disposable `.03` copy resolved 5,397 items and 1,118 craft recipes plus the
effective crop, vehicle, survival, fishing and moveable registries. Strict
validation preserves two known fishing raw-reference exceptions rather than
inventing an alias. The current capability inventory contains 27 existing and
37 proposed records with zero unclassified names. The command inventory separately
records `/goblin`, deterministic natural language, proposed commands, Qwen
intents, native API references, loopback administration and the audited absence
of repository RCON integration.

## Source priority and evidence vocabulary

Use `.03`'s installed build, loaded registries and enabled mods first; inspect
matching Java classes and vanilla call sites next. Official documentation is
discovery evidence, not proof of compatibility with the installed build.

| Label | Meaning |
| --- | --- |
| DOCUMENTED | Public API reference contains the interface. |
| REPO_EXISTING | Current Goblin code implements or references it. |
| STATIC_INSTALLED | Hash-matched installed files/classes contain it. |
| RUNTIME_RESOLVED | Actual loaded registry/binding resolves it. |
| MANAGED_ACTOR_NATIVE_CHECKED | Installed native operation was invoked against the real managed IsoZombie in a disposable fixture; this proves that specific native actor path, not gameplay movement, replication or full ability support. |
| ENGINE_TESTED | Dated real-game scenario verifies physical results and replication. |
| PROPOSED | Not an available ability. |
| UNSUPPORTED | Known incompatibility; do not expose to the planner. |

These labels describe different evidence, not automatic promotion stages.
No current-worktree capability has an active completion certificate. A narrower
OPEN_DOOR record still carries prior local engine-test evidence, but is not
marked complete. The dated
Milestone 1 and 2 acceptance files remain historical evidence: all six
Milestone 1 source hashes and five of eight Milestone 2 source hashes differ
from this worktree. Their scenario results must be revalidated before those
milestones can be claimed complete for the current build.

## Registry discovery

Official references: [ScriptManager](https://projectzomboid.com/modding/zombie/scripting/ScriptManager.html),
[Item](https://projectzomboid.com/modding/zombie/scripting/objects/Item.html),
[InventoryItem](https://projectzomboid.com/modding/zombie/inventory/InventoryItem.html).
The first two were retrieved 2026-09-19; the third is a reference to investigate.

`javap` inspection of the hash-matched installed game JAR confirmed:

- `ScriptManager.getAllItems(): ArrayList<Item>`.
- `ScriptManager.getAllCraftRecipes(): ArrayList<CraftRecipe>`.
- `getItem(String)`, `FindItem(String)` and `getCraftRecipe(String)`.
- Item definition getters: `getFullName`, `getDisplayName`, `getDisplayCategory`,
  `getActualWeight`, `getFileName`, `getModID`.
- `Item.getTags(): Set<ItemTag>`; `CraftRecipe.getTags(): List<String>`.
- `BaseScriptObject.getScriptObjectFullType()`, `isEnabled()`, `getObsolete()`.
- `CraftRecipe.isRequiresPlayer()`, `getInputs()`, `getOutputs()`.

Java signatures do not establish Lua exposure. Item definitions and inventory
instances use different identifiers/getters. No catalog export should create an
inventory item simply to discover its definition.

## Confirmed crafting compatibility hazard

Native class: `zombie.entity.components.crafting.recipe.CraftRecipeData`.
Installed `perform(IsoGameCharacter, List, List, ArrayList)` consumes inputs and
creates outputs, then casts the character to `IsoPlayer` at bytecode offset 65
to record player craft history. Passing IsoZombie to this public entry point is
therefore unsafe even though its parameter type is IsoGameCharacter.

Existing adapter: `server-java/src/com/horsetheunicorn/goblin/server/CompanionJobs.java`.
It deliberately invokes native consumption/output phases, skips player history,
rejects workstation/buildable recipes and protects reserved tools. This is
REPO_EXISTING, not blanket compatibility for every recipe: Lua callbacks and
nested native operations still require recipe-specific inspection. Partial
consumption errors must remain terminal rather than silently replaying a batch.

Installed vanilla caller:
`media/lua/shared/Entity/TimedActions/ISHandcraftAction.lua`.
Read-only source inspection on `.03` confirms `serverStart` creates HandcraftLogic,
sets containers, recipe and variable input ratio; `start` validates manually
selected inputs and configures animations. The full completion and replication
chain remains to be audited before recipe acceptance.

Source SHA256 (2026-09-19):
`ec72bdf147613fef617fbf57c88776fee5a58c05bb8dc80cb05075c90b753e2e`.

## Keep control surfaces separate

1. **Existing chat commands:** inspect `GoblinCommands.lua` plus Python natural
   language routing. `/goblin` and `!goblin` share a parser; an optional `debug`
   token is removed. Receiving a task acknowledgement is not completion.
2. **Proposed chat commands:** Section 24 entries remain unregistered until their
   capabilities pass acceptance. Do not put them in player help yet.
3. **Native API methods:** implementation primitives, never model-provided code,
   arbitrary method names, target coordinates or raw packets.
4. **Administrative server/RCON commands:** maintenance operations, never exposed
   through Goblin's gameplay capability vocabulary.

Existing direct-command authority starts at the authenticated `OnClientCommand`
player; `ownBody(player, ...)` resolves that player's companion. Physical orders
then call `Brain.setTask`. Base/spawn/status have separate existing paths.
The `despawn` branch additionally checks `Config.isAuthorizedPlayer`; it belongs
to the admin-only Goblin command inventory, not ordinary player help.

## Export safety decision

Use an explicit operator JVM opt-in on a disposable, matching dedicated server.
Enumerate after server startup in Java and write fixed catalog filenames outside
the IPC bridge. Do not add arbitrary evaluation, chat, RCON or Qwen export tools.
Leave production `.03` unchanged. Catalogs from a different mod set must not be
represented as `.03`'s loaded registry.

Live acceptance will separately exercise each approved high-level handler on a
managed IsoZombie, with before/after material and world state, authority handoff,
second-client observation, cancellation and restart checks. Export success alone
does not satisfy any of those physical-action tests.

## Loaded-content proof (23 September 2026)

The current reference export is bound to a 23 September exact copy of `.03`'s
installed scripts and configured Workshop items. It supersedes the 19 September
snapshot after changed configured Workshop roots were detected. The disposable
server exported the loaded registry and its selected-content SHA-256 fingerprint
is `c7fefb1cff630f72b8277acefdab7f796b55b62ed614edb9650e8ab854385b67`.
No live registry export was attempted on the stopped production server. An
unconfigured installed Workshop item also contained `GoblinSurvivor`; staging
and reconciliation now select only the server's explicit `WorkshopItems` IDs,
not every folder present under the Workshop cache.

The disposable server now emits SHA256 provenance through installed
`ZomboidFileSystem.getModIDs/getModDir/getModInfoForDir` and
`ChooseGameInfo.Mod.getCommonDir/getVersionDir`. `loadMod` bytecode confirms
common-before-version selection. Some installed mods are common-only; an absent
version directory is recorded, not guessed or replaced with another version.

`selected-common-version-roots-v1` hashes each regular file as compact UTF-8 JSON
`[relative/path,byte_count,sha256]` plus a newline, sorted by Java String order.
Each selected root records path, presence, count, bytes and digest. A mod digest
binds its ordered root records; the overall digest binds all mod records in
loaded order, using sorted JSON keys. This conservatively includes overridden
files inside selected roots; it excludes inactive version folders and disabled
submods. It is not an atomic whole-install snapshot. File size, identity and
mtime are checked around reads; redirects, special files and excessive input
are rejected.

`tools/reconcile_pz_stage.py` independently recomputes those hashes and compares
the staged files with the captured `.03` snapshot. The recorded result covers
68 selected mods plus vanilla Lua/scripts. The only allowed difference is the
candidate `GoblinSurvivor/42/goblin-server.jar`. Its old/new hashes are explicit
in `reference/pz-stage-reconciliation.json`. Thus the candidate's enabled-mod
fingerprint is deliberately different from production's selected-content hash.
This is loaded-registry evidence from a matching staged environment, not a claim
that the exporter was run on `.03` or that a physical job was performed.

## Milestone 1 navigation compatibility findings

`javap` inspection of the hash-matched Build 42 JAR confirms
`IsoZombie.pathToCharacter(IsoGameCharacter)` delegates through
`IsoGameCharacter.pathToCharacter` to `PathFindBehavior2.pathToCharacter` and
the inspected entrypoints contain no `IsoPlayer` cast. The candidate uses this
for long-distance FOLLOW, while retaining coordinate pathing as a Lua-binding
fallback and for stable nearby slots. Both native calls return void; only live
position progress can establish acceptance.

The candidate records primitive navigation state in ModData and keeps expiring
blocked-target/edge/approach memory only in weak runtime tables. One stalled
native route is retried once; a second no-progress interval becomes a blocked
result and a temporary blacklist rather than an infinite retry or teleport.
This is REPO_EXISTING plus STATIC_INSTALLED and boundary-test evidence. It is not
ENGINE_TESTED until the two-client local acceptance run succeeds.

## Access compatibility findings

### Container lock checks (September 26 follow-up)

Installed `media/lua/client/ISUI/ISInventoryPage.lua` uses
`IsoThumpable.isLockedToCharacter(playerObj)` to disable locked container access;
the adjacent matching-key display does not remove the padlock or consume a key.
Inspection of `IsoThumpable.isLockedToCharacter(IsoGameCharacter)` in the installed
JAR shows the IsoPlayer cast is guarded by both GameClient.client and instanceof.
The server path returns locked for a positive combination code, or for a
padlocked object when the actor inventory lacks haveThisKeyId(getKeyId()).
It otherwise returns false. This establishes static managed-actor compatibility,
not live execution or permission to invent a combination code.

The shared supply scanner/transfer and stockpile assignment/re-resolution now
use this native actor-aware result where available. Failed reads deny the
operation; ordinary containers without a lock interface retain normal access.
Unit regressions cover relocking after selection and native-read failure.
This change is not yet staged or multiplayer-verified. High-level CONTAINER
GAIN_ACCESS still remains unimplemented; do not infer completion from this fix.

Verified against the captured game JAR hash recorded above, and Goblin Lua files
that match the captured server byte-for-byte:

- `IsoDoor.ToggleDoor` delegates to `ToggleDoorActual(IsoGameCharacter)`.
  The latter obtains a nullable IsoPlayer at bytecode offsets 0–10. On the
  ordinary success path it changes state at991 and synchronizes at1066, then
  dereferences that player at1093 without a null guard. Managed IsoZombie use
  therefore has a post-mutation failure hazard. Existing Goblin Access requires
  both successful pcall and observed state; a native exception can report failure
  even after a world change. No new adapter or blanket engine patch is applied.
  Reproduce with the exact live Storm transformer set before choosing the fix.
- `IsoWindow.ToggleWindow(IsoGameCharacter)` does guard the nullable player at167,
  and explicitly handles an IsoZombie branch. However, installed vanilla
  `ISOpenCloseWindow.perform` uses the character openWindow/closeWindow action
  lifecycle, not a direct ToggleWindow in complete. Existing Goblin access has
  no established human opening-animation acceptance.
- `IsoCurtain.ToggleDoor(IsoGameCharacter)` has no player cast in its inspected
  entrypoint and invokes native sound/state synchronization. Current Goblin
  scanning covers IsoCurtain objects only; vanilla curtain dispatch also covers
  door-attached curtains. That variant remains a capability gap.
- `GoblinAccess.nextPathSquare` now reads `pathNextIsSet`, `pathNextX`, and
  `pathNextY` as either public fields or zero-argument methods. Installed
  `PathFindBehavior2` declares them as public fields. A boundary test exercises
  that exact shape; the installed Lua field binding still requires live proof.

The public [door](https://projectzomboid.com/modding/zombie/iso/objects/IsoDoor.html),
[window](https://projectzomboid.com/modding/zombie/iso/objects/IsoWindow.html),
[curtain](https://projectzomboid.com/modding/zombie/iso/objects/IsoCurtain.html), and
[pathfinding](https://projectzomboid.com/modding/zombie/pathfind/PathFindBehavior2.html)
pages were reachable on 19 September 2026. They are discovery references, not
evidence that these nested implementation paths are safe for Goblin. Native
call-site hashes, vanilla flow, authority routes, tests and missing multiplayer
evidence are recorded in `reference/goblin-capabilities.json`.

## Moveable repair and dismantle findings (inventory, not abilities)

The exact `.03` content copy's initialized ISMoveableDefinitions singleton was
captured after Lua readiness without invoking it. The hashed payload records 8
tool groups, 9 material groups, 36 scrap definitions and 19 repair definitions.
All checked references resolve through the installed catalog; Tag.Rope and
Tag.SewingNeedle remain tags. Five unqualified legacy strings have unique loaded
Base.* matches and are reported as aliases, not silently rewritten.

Installed repair flow calls `canRepairObject`, consumes selected required and
optional parts, rolls success, restores the eligible object/group only on
success, then calls `IsoObject.sync()`. The action constructor also stores
`character:getPlayerNum()`, and UI/halo/timed-action code remains in the chain.
The generic inventory/perk signatures therefore do not establish managed
IsoZombie support. Official [IsoObject](https://projectzomboid.com/modding/zombie/iso/IsoObject.html)
and [IsoGameCharacter](https://projectzomboid.com/modding/zombie/characters/IsoGameCharacter.html)
pages confirm the primitive surfaces only.

Installed `ISDismantleAction` requires unbroken base:saw and base:screwdriver
tags at <=1.6 X/Y distance. Loaded alternatives are Base.CrudeSaw,
Base.GardenSaw, Base.Saw and Base.Handiknife, Base.Multitool, Base.Screwdriver,
Base.Screwdriver_Improvised, Base.Screwdriver_Old. Completion drops contents and
randomized live `getBuildMaterials()` salvage before removing the object/stair
group or changing a floor sprite. `perform` references ISInventoryPage. Thus
retry safety and the complete managed-actor action lifecycle remain unresolved.
Official [IsoThumpable](https://projectzomboid.com/modding/zombie/iso/objects/IsoThumpable.html)
and [IsoGridSquare](https://projectzomboid.com/modding/zombie/iso/IsoGridSquare.html)
pages document the native primitives, not Goblin compatibility.

### Installed turnalerted lifecycle — 2026-09-24

The installed `media/actiongroups/zombie/turnalerted/to_walktoward*.xml`
transitions require `ActiveAnimFinishing`. Vanilla's corresponding AnimSets
Default.xml is non-looping. Installed AnimLayer bytecode emits that event from
`onNonLoopedAnimFadeOut` and `onNonLoopedAnimFinished`. Goblin's human fallback
must also be non-looping; a looping idle can strand the action context while
the native FSM already reports PathFindState and a valid path.

Do not treat the public ActionContext API as Lua-callable. The local Build
42.20.4 runtime returned the object but rejected indexing `getGroup` with
`attempted index ... of non-table`. The attempted Lua recovery was removed;
the packaged animation now follows the native completion lifecycle instead.
User accepted the resulting local fix. This does not prove all other public
ActionContext methods are exposed or establish a multiplayer milestone pass.
