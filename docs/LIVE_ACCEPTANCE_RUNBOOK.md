# Live acceptance runbook (Milestones 3–9)

## Autonomous food cycle and short speech (local implementation, live gates pending)

2026-09-29 live preflight: disposable Build 42.21 cache
`C:\Users\tomgr\Zomboid-GoblinFoodTest-20260929`, server-side Storm,
ordinary clients `m3path_61` and `m3witness_54` using saved credentials.
All 187 gameplay files matched source in the server and both direct/Workshop
client packages before staging the isolated-game autoconnect helper. Both
players entered with one present, control-ready Goblin each. Qwen reached
through a local SSH tunnel to the existing `.76` loopback endpoint. The
`m3path_61` short-greeting chat produced `CHAT_RESULT npc_spoke` in 4392 ms;
its complete brief reply was visible in the client. Logs are under that
cache's `Logs`, including `goblin-python-agent.log`. These observations are
startup/chat evidence only: food custody, native cooking, storage replication,
and interruption/restart gates below remain pending.

The new survival controller reuses **FORAGE, COOK and DELIVER**, not a new
native action or player substitute. Automatic runs require an online owner
idle for 30 seconds, autonomy/free will enabled, a loaded base nearby, and
FOOD, INBOX or OVERFLOW storage. If the loaded registry proves no food storage
exists, the internal `PREPARE_FOOD_STORAGE` capability builds one crate on a
safe, reachable indoor base square (three planks, three nails, hammer), verifies
the native object, and assigns that exact owned crate to FOOD. The existing
Goblin provision policy applies to building supplies; no food is conjured.
Already created marked crates are reused after interruption rather than
duplicated. Unknown/unloaded storage never triggers construction. Goblin stays
in god mode: the reserve is for the owner/base, not Goblin's own nutrition.
Explicit owner goals, movement,
combat and WAIT take precedence. No offline-cell loading or zero-player
simulation change is included.

New owner chat command: `!goblin goal food`. Existing commands remain separate:
`!goblin storage food`, `!goblin cook food`, `!goblin deliver FOOD`, and
`!goblin freewill on/off`. `!goblin cancel food` cancels both the running job
and automatic re-arming; a new `goal food` order enables it again. These are
Goblin commands, not native API names or administrative/RCON commands.

Bridge config options: `GoblinFoodSurvivalEnabled` (default true) and
`GoblinFoodReserveItems` (default 4, range 1–10). This is a reserve of **usable
food instances**, not a calorie/day calculation. Only readable, native Food
instances with hunger value count; raw, rotten, burnt, poisonous and spice
items do not count as ready food. Raw ingredients are cooked when available;
otherwise the existing installed-forage roll supplies food. The food-only
filter skips forage definitions with poison chance rather than bypassing
their IsoPlayer-dependent poison callbacks. No food is conjured.

Installed vanilla references checked: `Food:getHungerChange`, `getPoisonPower`,
`isRotten`, `isBurnt`, `isSpice`, `isCookable`, `isCooked`, and
`isbDangerousUncooked` in inventory/eating/foraging Lua; installed
`forageSystem.itemDefs`, `pickRandomItemType` and `doPoisonItemSpawn` in
`media/lua/shared/Foraging/forageSystem.lua`. Compatibility and replication
still need managed-IsoZombie runtime evidence, not just method presence.

| Gate | Procedure | Required evidence |
| --- | --- | --- |
| Full cycle | With two clients, assign FOOD storage below four usable items. Supply real raw ingredients and a powered stove; idle. | Owner sees approach, pickup, loading, native cooking, collection and storage. Server logs the same item IDs through custody. Witness sees the same cooked food and count, with source ingredients gone. |
| Forage fallback | With no raw ingredients nearby, idle with a depleted reserve. | Installed forage rolls yield real acceptable food, physically collected and delivered. No invented food types or fake cooking claims. Both clients see storage changes. |
| Verified completion | Observe `FOOD_RESULT ... VERIFIED_FOOD_STORED`. | Selected IDs are in real base storage, absent from Goblin; reserve meets target. No completion from model text alone. |
| Failure/replanning | Use a cold stove, full destination, blocked route and unavailable storage. | Cold stove leads to ready-food forage; full storage retains cargo; other failures back off. Unloaded/unknown storage never means empty, and no false success occurs. |
| Interrupt/restart | Move, issue WAIT, turn free will off, disconnect, or save/restart mid-cooking/delivery. | Following/orders win; heat lit by Goblin is switched off on cancellation. Nearby tracked food is recovered without remote transfer. Restored cargo IDs are reconciled without duplication; no orphan ACTIVE goal. |
| Memory and speech | Let the Python agent observe shortage, block and completion; ask what happened. | Survival facts reach persistent memory and replies reflect actual outcomes. Both clients see brief, readable speech (at most 140 characters and 140 UTF-8 bytes); journals remain unchanged. |

### Local additions awaiting a new runtime test

Ratspit's running trace showed successful collection/delivery followed by
repeated no-op FORTIFY/FOLLOW transitions. The local scheduler now checks the
same BuildingDef as the fortification worker, backs off that selection for
five minutes, and measures Qwen grace from real movement/work instead of
speech or task-sequence churn. Explicit FOLLOW/WAIT and movement recall remain
priorities. The 2026-09-29 restart staged all 189 current gameplay files with
matching hashes in the disposable server and both direct/Workshop client
packages. The daemon was restarted from this worktree with the same memory
database and Qwen tunnel. Server boot confirmed native helpers with no client
Storm hooks. Ratspit's client entered and started caretaker FARM work. The
other client crashed three times before world entry in native `glfw.dll`
`Display.processMessages`, including a visible-launch retry. Crash reports
are retained in the isolated `client-game` directory. Automated T/text input
did not produce a visible greeting, so no new chat success is recorded.
This is not two-client acceptance or completed food-crate/corpse proof.

Experimental command `!goblin clean corpses` (alias `!goblin corpses`) routes
through MOVE_CORPSE. It is **disabled by default** by
`GoblinCorpseCleanupEnabled=false`, pending native actor/multiplayer proof.
Installed 42.21 pickup uses `pickUpCorpse(body, "BwdDrag")`; drop uses
`setDoGrappleLetGo()`. Pickup transfers the original inventory into a
grapple-only IsoZombie; drop creates a new world corpse. The handler verifies
that native network identity and original inventory/item IDs survive, rather
than requiring the old world object ID to remain unchanged. It never clones,
deletes, burns, buries or remotely relocates a corpse. Only zombie remains in
the exact house, a loaded safe outside ground-level pile, an online explicit
owner order, and at most twenty bodies are allowed. Player remains, animals
and cross-floor dragging are excluded. Fixture tests are not native proof.
Before enabling generally, test pickup/drag/drop with contents, door traversal,
two-client convergence and interruption/restart recovery.

### 2026-09-29 local dismantling/corpse command correction

The installed 42.21 `canScrapObject` returns `canScrap and haveTool and
haveTool2`, which may be the saw inventory item, not the literal boolean
`true`. A read-only local native probe confirmed that result on the managed
Ratspit actor with both tools present. All four dismantling eligibility checks
now accept native Lua truthiness; false, malformed and throwing results still
refuse without destruction. Plain "break down", "take apart" and "disassemble"
furniture orders use the existing one-object job; a named chair cannot select
a closer cabinet. This is not permission to tear down walls or the whole house.

Live corpse orders were rejected by `Brain.execute` because MOVE_CORPSE was
missing from both Authority's privileged and owner-job action lists. It now
requires and consumes the same matching owner's one-use chat grant as other
physical jobs. Plain "remove the corpses" also dispatches directly from the
authenticated game chat event. No offline/free-will authorization was added.
Native corpse cleanup remains disabled by default; the disposable local
`Zomboid-GoblinFoodTest-20260929` config alone enables it for physical testing.
81 targeted tests and the 67-record catalog consistency check passed. Native
eligibility and routing evidence are not proof of removal, salvage, dragging
or multiplayer replication; record those live results separately below.

The subsequent native drag trace reproduced `CORPSE_PICKUP` followed by
`CORPSE_CUSTODY_LOST`, with `GrappledDied` on both actors and the carried actor
dead. This is real native loss, not a contents-signature false positive.
Installed 42.21 `ZombiePacket.set(IsoZombie)` includes its `grappledBy`
`PlayerID` and shared grapple type only when the grappler is an `IsoPlayer`.
Goblin's managed `IsoZombie` therefore cannot replicate that relationship
through the vanilla zombie packet. The local adapter publishes the verified
corpse ID/outfit/type with a five-second lease through the authoritative Goblin
roster, then replays only the reciprocal native relationship on clients. It
does not create, heal, reposition or delete corpses. Native release uses
`LetGoOfGrappled("Released")`; `PlayerDraggingCorpse` is not used because its
installed implementation casts the actor to `IsoPlayer`.
The next live attempt received the link but exposed a Kahlua boundary:
`BaseGrappleable.acceptBeingGrappledBy` is not callable through that wrapped
helper. The source adapter now calls the character-level `Grappled` method
instead. Seventeen focused corpse/client-chat tests passed after that change,
but successful native carry/drop and two-client convergence remain unproven.
The user paused corpse work and authorized publishing the other accepted
updates. `corpseCleanupEnabled=false` remains the release default.

Release validation found a pre-existing character-report checksum mismatch:
`Goblin_Community_Final_report.json` records an older GoblinHead.x hash. Both
the report and the working mesh are unchanged from `d96a774`; this release
does not rebuild or alter the accepted appearance assets.

The focused fixtures verify logic and exact custody, with mocked movement,
heat evolution and packets. **They are not a substitute for these live gates.**
Nothing in these fixture results marks a catalog capability physically
complete. Publication is authorized separately by the user's release request.

Written 2026-09-27 alongside the Milestone 4–8 implementation. Everything below
is **pending live evidence**. Lua fixtures and Python tests show the logic is
consistent. They do not show that a managed IsoZombie can execute the native
calls, that clients see the change, or that it survives a save/restart. Record
each gate in `ABILITIES_V2_PROGRESS.md` with its source hashes. Mark a catalog
record `complete` only after its physical-evidence review.

## 0. Preflight (every session)

1. Rebuild the disposable server and both no-Storm client packages from this
   worktree. Then run `python -m tools.check_pz_test_package --package-dir <dir>`
   for the server copy and for both copies in each client cache. The file count
   is now 180 gameplay files (171 + 9 new server modules).
2. Run `python -m unittest discover -s tests -p 'test_*.py'`. The current
   baseline is 685 tests: two declared expected failures and one art-asset
   error (custom mesh/texture not in this repo checkout).
3. Run `python -m tools.check_goblin_inventory` and `python -m tools.check_pz_catalog`.
4. Confirm the server log shows
   `CAPABILITY_REGISTRY_READY count=25 tasks=CHANGE_TIRE,CHOP_WOOD,CLOSE_CURTAINS,...`.
5. Stage the read-only witness `tools/probes/Milestone4To6Witness.lua` on the
   second client, with `Lua/goblin-m46-witness.flag` containing the witness
   account name. Remove both after the session.

Use two accounts: the **owner** (issues orders) and the **witness** (observes
only). Capture the server stdout log and both client `console.txt` files.

## 1. Milestone 3 — remaining access gates

| Gate | Procedure | Pass criteria |
| --- | --- | --- |
| Locked gate, two-client rerun | Re-run the `Milestone3GateRouteProbe/Observer` pair as corrected on 09-27 (server-origin gate sent with `transmitAddObjectToSquare`; observer matches the Goblin by online ID). Server-side runs already pass; see V2_STATUS. | Both clients log matching `ready` → `terminal` identities: padlock removed, key consumed, gate open, Goblin on the `to` side. |
| Window breach | Owner types `/goblin breach building` beside a house whose only entry is a closed window. | Server logs a breach route. The window is smashed or opened on **both** clients. Goblin is inside. Save and restart, then confirm the window state persisted. |
| Alternate entrance | Lock the front door without a key and leave the back door open. Order `/goblin access building`. | The route falls back to the back door. The front door stays locked on both clients. |
| Fence/gate after restart | Cross a fence (`access yard`), save, restart, repeat. | The same traversal works after restart. No duplicate or phantom crossing. |
| Vehicle two-client | `enter`/`exit`/`unlock vehicle`/`start vehicle` with the witness watching. | The witness sees seat occupancy, the lock flag and the engine state change. |
| Access interruption | Start `access building`, then disconnect the owner mid-route. Reconnect. | The job reports `INTERRUPTED` and does not repeat a toggle. After a restart during the route, the restored job completes or reports `TARGET_CHANGED`. |
| Safehouse rules | Repeat the locked-door order inside another player's safehouse and inside your own. | Other safehouse: `PERMISSION_DENIED`. Own house: the locked door still opens (intended behavior). |
| Any lock | With no key: a key-locked house door from outside, a padlocked gate, a combination-locked door, a locked car door (`/goblin enter vehicle`). | Each opens; the server logs `LOCK_PICKED` for padlock/combination. Both clients see the lock cleared and the door open. |
| Free-will access | Enable free will and idle beside a locked house. | If Qwen picks GAIN_ACCESS, the server logs `QWEN_COMMAND ... action=GAIN_ACCESS status=accepted`, not "unknown target kind". |

## 2. Milestone 4 — base and logistics

Setup: set a base inside a house. Stand beside a crate and type
`/goblin storage inbox`. Assign two more containers with `storage food` and
`storage materials`, and optionally one with `storage overflow`.

| Capability | Procedure | Pass criteria |
| --- | --- | --- |
| Assignment | `storage food` beside a crate. | Owner sees `container assigned to FOOD`. The witness log shows `category=FOOD` for that square (modData replicated). The assignment survives save/restart. |
| SORT_STORAGE | Put tinned food, nails and planks in the INBOX. `/goblin sort`. | For each moved item, the server `SORT_TRANSFER stage=pickup` and `stage=deposit` lines show the same `item_id`. The witness storage lines show that ID leave the INBOX and appear in FOOD/MATERIALS. No other item IDs change. |
| Full-container fallback | Fill FOOD so it has no room, then sort. | Food goes to OVERFLOW. With no OVERFLOW it stays in the INBOX, or is `returned` to its source. Nothing is dropped. |
| Sort all | `/goblin sort all` with a loose floor item and a powered fridge holding food. | The floor item is stored. Fridge food is **not** moved. Other players' containers are untouched. |
| Restart mid-sort | Stop the server (SaveAll) while Goblin carries items. | After restart there is no second pickup. Log shows `reconciled_*`, carried items are delivered, and total item-ID counts are conserved. |
| FETCH_ITEM | `/goblin fetch Base.Nails 3` while standing away from base. | Goblin walks to base, then to the owner. The owner's inventory gains exactly those IDs (`FETCH_TRANSFER stage=handover`). Base storage loses exactly those IDs. A shortage reports `N of 3`. |
| DELIVER | Hand Goblin loot, then `/goblin deliver`. | Only the listed IDs are stored, by category. Toolkit items stay with Goblin. With no room and no `floor`, the result is `BLOCKED` and cargo is kept. |
| REPAIR_STRUCTURE | Damage a wooden door or furniture to 20–95%. Put 2 planks and 4 nails in base storage. `/goblin repair base`. | Planks and nails leave storage. `STRUCTURE_REPAIR result=repaired` appears, or `skill_fail` (materials consumed, as in vanilla). The witness `damaged` line disappears or persists to match. Health persists after restart. Watch for any IsoZombie exception from `getRepairSkillChance`/`canRepairObject`. |
| Broken glass | Smash a base window. `/goblin repair base`. | Glass is removed on both clients (`isGlassRemoved`). |
| Boarding/curtains replication | `/goblin maintain base` and `/goblin close curtains`. | The witness sees planks and closed curtains. Both survive restart. |

## 3. Milestone 5 — survival (registered adapters only)

| Capability | Procedure | Pass criteria |
| --- | --- | --- |
| CHOP_WOOD | `/goblin chop` near a tree. | Server `CHOP_WOOD felled`. The witness sees the tree removed and logs on the ground. **This is the first managed-actor `IsoTree.WeaponHit` call.** If it throws or does no damage, the job reports `UNSUPPORTED`/`ENGINE_ERROR`. Record that result either way. |
| TREAT_PLAYER | Get scratched. Remove all bandages. `/goblin bandage me`. | Server `PROVISION item=Base.Bandage`. The owner's health panel shows the wound bandaged (check the owner's own screen). |
| FORAGE | Stand at a forest edge. `/goblin forage 3`. | Three `FORAGE ... item=` lines; Goblin walks between spots with the loot animation, then delivers the finds to the base container. |
| CHECK_TRAPS | Place a baited trap and an empty trap near the base; wait for a catch. `/goblin traps`. | `TRAP_COLLECT` for the full trap; the empty trap shows bait (carrots) on both clients; the catch reaches the base. No error in the server log. |
| COOK | Put raw steak/eggs in the fridge next to a powered stove. `/goblin cook 2`. | The stove switches on, the food appears in the oven, then leaves it cooked; `COOK ... cooked=2`; the stove switches off; the food is delivered home. |

| Trap placement | Stand in a forest. `/goblin traps place 2`. | Two `TRAP_PLACED` lines; both clients see two box traps with bait; a later `/goblin traps` finds them. Save/restart: the traps and bait persist. |
| Campfire | Stand outdoors with no stove within ten tiles, raw meat in your inventory dropped on the ground. `/goblin cook 1`. | `CAMPFIRE_BUILT`; both clients see a lit fire; the meat cooks and comes out; the fire goes out. |
| Pot of soup | Carrots and potatoes in a nearby container. `/goblin cook soup 3`. | `POT_FILLED ... ingredients=3` (and no `POT_INGREDIENT_ERROR`); the pot cooks on the stove/fire and is delivered home; eating it gives the ingredients' nutrition. |

Fishing is not implemented.

## 4. Milestone 6 — vehicle service

Park a car and switch the engine off. Parts, tires, petrol and batteries are
conjured when Goblin has none, so nothing needs to be staged.

| Capability | Procedure | Pass criteria |
| --- | --- | --- |
| VEHICLE_INSPECT | `/goblin vehicle inspect` | The reply's fuel, battery and tire figures match the mechanics UI on both clients. Nothing changes. |
| REFUEL_VEHICLE | `/goblin vehicle refuel` | The can's fluid drops by exactly the tank increase. The witness `GasTank` amount rises. Repeat at a pump with piped fuel. |
| CHANGE_TIRE | Deflate one tire. `/goblin change tire TireFrontLeft`. | The witness shows the part item ID swap (old ID now in Goblin inventory) and pressure at capacity. Installation respects the Jack and LugWrench requirements. |
| REPLACE_PART Battery | `/goblin replace Battery` | The engine door opens, the battery ID swaps, and the door closes. The witness sees `battery=` change. |
| Brakes (no recipe gate) | `/goblin replace BrakeFrontLeft` | Works without Basic Mechanics; a conjured brake is installed (`PROVISION item=Base.NormalBrake...`). |
| No key needed | Lock the car, give Goblin no key, `/goblin remove Battery`. | Proceeds; no `LOCKED` refusal. |
| Battery charge | Drain the battery (leave the headlights on). `/goblin vehicle charge`. | `VEHICLE_BATTERY_CHARGED`; the witness sees battery 100%. |
| Rollback | Force a failed install roll (low-skill part). | The item stays with Goblin with reduced condition. The part slot stays empty on both clients. |
| Restart | Restart mid-`change tire`. | No second install. The restored job completes from the installed item ID. |

Also confirm that `BaseVehicle.getSqlId` resolves on the dedicated server. The
restart path depends on it. If it does not resolve, restart reconciliation
falls back to `TARGET_UNLOADED`.

## 5. Milestone 7 — Reflex and Qwen

1. `python -m tools.generate_reflex_dataset && python -m tools.train_reflex`
   must print `non_social_leaks: 0` and exit 0.
2. With Qwen running: "Goblin, good morning" gets an instant reply, the admin
   snapshot shows `SOCIAL:GREETING`, and there is no Qwen request.
   "Goblin, follow me" reaches the deterministic route or Qwen.
3. Stop Qwen. Greetings still get replies. Orders still run through
   `directIntent`. Other chatter gets the jammed-radio line.
4. Rename `reflex_model.json`: `admin_snapshot().reflex.available == false`
   and chat falls back to Qwen.
5. Confirm latency in the log detail (`reflex GREETING in 0.xx ms`).
6. Qwen-started jobs: say "Goblin, go grab me three tins of food from home" and
   "Goblin, swap the car battery". Check that the server logs
   `QWEN_COMMAND ... action=FETCH_ITEM status=accepted` or
   `action=REPLACE_PART status=accepted`, and that the job then runs exactly as
   the slash command does. Replaying the same request ID, or sending a job with
   an expired or missing grant, must be rejected.
7. Two owners chatting at once: each Goblin acts only on its own owner's
   request, and replies arrive in order.

## 6. Milestone 8 — goals

1. `/goblin goal secure`, then stand still for 30 s inside the base. The server
   logs `GOAL STEP ... INSPECT_BASE`, `MAINTAIN_BASE` and `CLOSE_CURTAINS`, each
   followed by a `GOAL RESULT`.
2. Spawn or lure a zombie near you mid-step. Expect
   `GOAL INTERRUPT reason=INTERRUPTED_COMBAT`. Goblin fights, then resumes the
   same step without consuming an attempt.
3. Walk more than 15 tiles away mid-step. Expect `INTERRUPTED_RECALL` and
   Goblin follows.
4. `/goblin goal organize every 30`, then save and restart. `goal list` shows
   the same state, and the cycle re-arms after 30 minutes.
5. Remove all planks and run `goal repair`. Expect `MISSING_MATERIAL` →
   WAITING (10 min) and FAILED after 3 attempts.

## 6b. Conjured supplies

1. With no planks nearby, `/goblin fortify base`. The server logs `PROVISION item=Base.Plank`
   and `PROVISION item=Base.Nails`, and the windows get boarded. Check on the
   server and both clients that no conjured item shows up in any container or on the floor.
2. `/goblin deliver` and `/goblin sort all` while Goblin carries conjured leftovers:
   they stay in his inventory.
3. Kill the Goblin while he carries conjured items: his corpse must hold none.
4. Check that the per-minute budget stops a stuck job (`conjuring limit reached`).

## 6c. Free will, memory and meetups

1. Stand still for over a minute. Within about 40 s Goblin announces a job
   (often with a complaint), and the server logs a `QWEN_COMMAND ... status=accepted`
   for a job action with no chat. `/goblin state` shows the job.
2. Walk 20+ tiles away mid-job: Goblin drops it and follows. Pull a zombie
   close: same. Give `/goblin wait`, then idle: Goblin never replaces WAIT.
3. `/goblin freewill off`: only scripted chores resume after the idle timer.
   Then `/goblin freewill on`.
4. Hurt the owner (fall damage). Within seconds Goblin reacts (treat or comment).
   Later chat ("do you remember the kitchen?") draws on memory. Restart the
   agent and check that trust and places persist (`*.mind.sqlite3`).
5. Two players with Goblins stand within 12 tiles, both idle: the Goblins
   trade 2–4 lines, and no item moves between them.
6. After an in-game day passes, the agent admin snapshot `free_will.stats.journal`
   increments.

## 6d. Sentience

1. Start the agent with free will on. Within a minute the agent log shows
   `SENTIENCE owner=... decision=new ... goal=... step=...`, and the admin
   snapshot `sentience` lists his mood, goal and plan.
2. Stand still: his free-will jobs follow the plan's steps in order; after each
   job's `COMMAND_RESULT ... COMPLETE` the next step runs.
3. Walk around (don't stop): no chores start, but the log keeps showing
   `SENTIENCE` lines when things happen (new rooms, night coming).
4. Get hurt mid-plan: a `decision=interrupt` reflection within ~20 s, usually
   a spoken line, a TREAT_PLAYER step, then the old goal resumes.
5. Praise or insult him in chat, then ask what he thinks of you: the reply
   reflects his opinions. Restart the agent: mood, goal and plan persist.

## 7. Milestone 9 — Offline Life (not implemented)

No offline chore is registered. Every new capability declares
`offline_allowed=false`. First prove the zero-player mechanism on `.03`: with
no players online, does the server keep a Goblin's chunk loaded and tick the
`IsoZombie`? Record chunk load state and positions over 10 minutes.
Implementation starts only after that evidence exists.
