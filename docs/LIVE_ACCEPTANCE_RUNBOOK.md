# Live acceptance runbook (Milestones 3–9)

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

Fishing, trap placement and campfire/pot cooking are not implemented.

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

## 7. Milestone 9 — Offline Life (not implemented)

No offline chore is registered. Every new capability declares
`offline_allowed=false`. First prove the zero-player mechanism on `.03`: with
no players online, does the server keep a Goblin's chunk loaded and tick the
`IsoZombie`? Record chunk load state and positions over 10 minutes.
Implementation starts only after that evidence exists.
