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
   baseline is 633 passing tests with two declared expected failures.
3. Run `python -m tools.check_goblin_inventory` and `python -m tools.check_pz_catalog`.
4. Confirm the server log shows
   `CAPABILITY_REGISTRY_READY count=22 tasks=CHANGE_TIRE,CHOP_WOOD,CLOSE_CURTAINS,...`.
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
| TREAT_PLAYER | Get scratched. Put a bandage in base. `/goblin bandage me`. | The owner's health panel shows the wound bandaged. The bandage ID leaves storage. `syncBodyPart` must reach the owner client: check the panel on the owner's own screen. |

Cooking, tailoring, fishing, trapping and foraging are **not registered**.
They stay proposed until a managed-IsoZombie native path is identified.

## 4. Milestone 6 — vehicle service

Park a car and switch the engine off. Put a petrol can, a spare tire and a
charged battery nearby.

| Capability | Procedure | Pass criteria |
| --- | --- | --- |
| VEHICLE_INSPECT | `/goblin vehicle inspect` | The reply's fuel, battery and tire figures match the mechanics UI on both clients. Nothing changes. |
| REFUEL_VEHICLE | `/goblin vehicle refuel` | The can's fluid drops by exactly the tank increase. The witness `GasTank` amount rises. Repeat at a pump with piped fuel. |
| CHANGE_TIRE | Deflate one tire. `/goblin change tire TireFrontLeft`. | The witness shows the part item ID swap (old ID now in Goblin inventory) and pressure at capacity. Installation respects the Jack and LugWrench requirements. |
| REPLACE_PART Battery | `/goblin replace Battery` | The engine door opens, the battery ID swaps, and the door closes. The witness sees `battery=` change. |
| Recipe gate | `/goblin remove BrakeFrontLeft` | Expected refusal: needs the 'Basic Mechanics' recipe. **Decision needed:** keep the refusal, or have Goblin learn Basic Mechanics. |
| Key gate | Lock the car, give Goblin no key, and try `remove Battery`. | `LOCKED` until the car is unlocked (`/goblin unlock vehicle`) or a key is carried. |
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

## 6b. Real-material conservation

1. With no planks nearby, `/goblin fortify base` must report a shortage and must
   not change any window.
2. Add known planks and nails, retry, and verify exact before/after counts on the
   server and both clients.
3. Repeat for bandages, vehicle parts and petrol. Missing materials must produce
   `MISSING_MATERIAL`; successful work must consume or transfer the exact real item.
4. Save/restart between acquisition and use, then verify identity and counts are
   reconciled without duplicates or lost items.

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
