# Goblin Abilities V2 checkpoint — 2026-09-26

The full V2 specification is not complete. This checkpoint preserves the accepted
companion foundation and distinguishes implemented code from live acceptance.

User clarification (September 26): Goblin opening locked doors is intended
behavior. Do not treat a keyless opening alone as a defect or add restrictions
to prevent the accepted behavior. Consistent world state and replication still
require verification; earlier missing-key fixture results are historical tests,
not a new user requirement to deny access.

## Completed scope

- Section 31: installed runtime catalog and compatibility inventory cover 64
  capability records. The consistency checker passes with explicit proof gaps.
- Milestone 1: follow/navigation behavior is user-accepted. Preserve it while
  testing later abilities; older source-bound records remain historical.
- Milestone 2: the additive capability framework is closed for its framework
  scope: registry, primitive task payloads, structured results, error containment,
  cancellation and terminal replay prevention. Nine adapters are registered.
  See MILESTONE2_CLOSEOUT.md for actual crafting evidence and its limits.

The old Milestone 2 live manifest does not match every current source hash.
Its strict verifier correctly rejects certification of the current build; that
record is not a substitute for fresh per-ability multiplayer/reload testing.

## Implementation checkpoint — 2026-09-27 (code and fixtures only)

The following capabilities are now implemented and registered. Each has Lua
fixture tests. **None is live-verified.** The live gates are listed in
`LIVE_ACCEPTANCE_RUNBOOK.md`. Registry: 25 capabilities.

| Milestone | Added | Key design points |
| --- | --- | --- |
| 4 | Storage categories (`storage CATEGORY`), `SORT_STORAGE`, `FETCH_ITEM`, `DELIVER`, `REPAIR_STRUCTURE`; `MAINTAIN_BASE` now chains native repairs after boarding | A primitive per-item ledger (native item ID) is persisted in the task payload and reconciled after interruption or restart. Full-container fallback: same category, then OVERFLOW, then back to source. Cold-storage food is never removed. Repair uses the installed `ISMoveableSpriteProps` eligibility, parts and chance. Parts leave through server custody (no actor-inventory packet). |
| 5 | `CHOP_WOOD` (IsoTree.WeaponHit), `TREAT_PLAYER` (BodyDamage.SetBandaged), `FORAGE`, `CHECK_TRAPS`, `COOK` | Toolkit axe; bandages carried, nearby or conjured. Foraging, trap runs and stove cooking: see "Survival life" below. Tailoring is covered by hand-craft recipes (`CRAFT`); fishing is not implemented. |
| 6 | `VEHICLE_INSPECT`, `REFUEL_VEHICLE`, `INSTALL_PART`, `REMOVE_PART`, `REPLACE_PART`, `CHANGE_TIRE`, `VEHICLE_SERVICE` | Vanilla install tests need `getPlayerNum`, so they are re-evaluated server-side. `requireInstalled/Uninstalled` and the engine-door open/close are enforced. Goblin knows every recipe, profession and trait (brakes and other Basic Mechanics parts work) and ignores the mechanic key rule. `VEHICLE_SERVICE` now charges a flat battery in place with his own charger (`vehicle charge`, "charge the car battery"). |
| 7 | `goblin_zomboid/reflex.py`, dataset generator, trainer, shipped `reflex_model.json`; `goblin_zomboid/quotes.py` | Per the latest owner direction, Qwen remains the primary conversational voice and combines Lenin/Stalin flavor. It sees the last 12 lines of that player's conversation, a Reflex `social_hint`, and 1-2 sourced quotes. Known misattributions are forbidden, and real atrocities are off-limits for jokes. The small Reflex classifier routes and supplies safe canned lines only when Qwen is offline or fails. Orders always bypass canned replies. |
| 8 | `GoblinGoals` (`goal secure/organize/repair/vehicle/nails [every N]`, `goal list`, `cancel`) | Persistent step records. Priority selection. Maintenance cycles. Combat and recall interrupts do not consume attempts. Replanning is driven only by the capability result code. |
| 3/9/10 | No gameplay change | M3 remains live verification only (runbook §1). M9 needs zero-player proof first. M10 stays deferred. |

Qwen may start every capability job (base, logistics, survival, vehicle
service) on the speaking owner's behalf. The server mints a one-use chat grant
when the owner addresses their Goblin. Qwen's response must carry that grant.
GoblinBridge consumes it, and only then does `Brain.execute` accept the job
(`owner_authorized`). Commands without a grant, and offline/autonomous grants,
are refused. Breach still needs the explicit `/goblin breach` command. One Qwen
service drives every player's Goblin: it answers each owner's chat in turn,
with that Goblin's own context, and can only control the Goblin whose chat it
is answering.

Reusable tools come from Goblin's persistent toolkit. Consumables and materials
for Goblin's own work are conjured when he has none (next section).

### Conjured supplies (GoblinProvision), restored 2026-09-27

Owner direction: Goblin spawns all his own parts and supplies. Codex had removed
this; it is back. `GoblinProvision.create` makes the item straight in Goblin's
inventory, marks it `GoblinConjured`, and has a per-minute budget
(`GoblinProvisionEnabled`, `GoblinProvisionPerMinute`). These jobs conjure what
they lack before touching base stock:

- planks and nails for fortifying (explicit orders, free will and idle chores
  alike) and structure repair
- missing recipe inputs for hand crafting
- seeds and a filled water bottle for farming
- replacement vehicle parts and tires, petrol (an emptied conjured can is
  discarded), and bandages
- bait for trap runs

Quarantine rules keep the player economy intact:

- Conjured items are refused by every container, floor and hand-over path, and by sort, fetch, deliver, loot and stockpile.
- Crafted outputs made from conjured inputs are marked too, and are discarded rather than dropped if Goblin's inventory is full.
- Conjured items are destroyed if Goblin dies.

Consuming or installing them is the point: a conjured tire in the car, a
conjured plank on the window. Salvage still exists but now only runs when
conjuring is switched off.

### Skills, recipes and locks, 2026-09-27

- **Skills and recipes:** every perk is 10 (GoblinIdentity) and Goblin now also
  knows every recipe (`setKnowAllRecipes`). Vehicle recipe, profession and
  trait gates always pass.
- **Doors:** Goblin opens any door, locked or not. He picks key locks from
  either side, custom locks, padlocks and combination locks (a matching
  padlock key is still used the native way when he has one). Locked vehicle
  doors are picked the same way, and the vehicle mechanic-key rule is gone.
  Barricades and destroyed doors still stop him. **Other players' safehouses
  stay protected**: Goblin will not unlock or open anything inside a safehouse
  his owner is not a member of.
- **Free-will access:** "gain access to a building/room/yard/container" chosen
  by free will was rejected by the Python action gate ("unknown target kind").
  Those semantic kinds are now accepted. Breaching (smashing) still needs the
  explicit `/goblin breach` command.

### Survival life, 2026-09-27

- `FORAGE` (`/goblin forage [1-10]`, "go foraging"): walks to outdoor
  forage-zone ground within 14 tiles of the owner and searches 5 s per spot. The
  installed `forageSystem` rolls a real item for the zone, month, time and
  weather. Finds are ordinary cargo and go to the base with his next delivery.
- `CHECK_TRAPS` (`/goblin traps`, "check the traps"): visits every trap within
  30 tiles of the base (or owner) that holds a catch or lacks bait. Catches are
  collected with the native `removeAnimal` (live ones are dispatched, so he
  carries the corpse/food item). Empty traps are re-baited with conjured
  carrots, owned by the player. `/goblin traps place [1-5]` ("set some traps")
  builds new box traps from conjured trap items on open outdoor ground in a
  trapping zone within 12 tiles of the owner, the same way the vanilla placing
  code does, owned by the player, and baits them.
- `COOK` (`/goblin cook [1-5]`, "cook some food"): takes raw cookable food from
  within eight tiles, loads the nearest stove/oven/microwave or campfire,
  switches it on or lights it, and takes each item out once the engine reports
  it cooked. The heat goes back off and the food goes home as cargo.
  - `/goblin cook soup|stew [1-6]` ("make some stew"): Goblin fills a fresh pot
    of water (his own) with real ingredients from nearby storage through the
    installed evolved recipe, cooks the pot, and brings it home. The soup is
    real food for the player.
  - No stove or fire within ten tiles: he builds a campfire beside the owner
    (outdoors), feeds it his own firewood, and puts it out when the food is
    done. The fire pit stays.

Qwen can start all three for the owner and choose them by free will.

### Free will, memory and social life

Owner direction, 2026-09-27: Goblin should act like a player who never idles.
He may grumble about the work, but he always has something to do. He has no
survival needs of his own, and his skills are already maxed (GoblinIdentity
sets every perk to 10).

- **Situation report** (`GoblinSituation.lua`): each online companion's
  telemetry carries labels and counts only, never coordinates. It covers time,
  weather, threat level and direction, room, the owner's health, wounds and
  moodles, base damage and stock shortages, vehicle state, carried categories,
  nearby Goblins, and a sequence-numbered log of recent events (jobs, kills,
  hordes, owner hurt).
- **Free-will loop** (`service._think_tick` → `QwenClient.propose_think`): while
  the owner is idle for 10 s or more and Goblin is following, Qwen picks one
  job at least every 40 s (15 s per Goblin when there are more) and narrates or
  complains about it. It runs on a background thread, so chat always comes
  first.
  - Publishing uses a per-Goblin companion grant (`Authority.issueCompanion`:
    90 s, one use, owner jobs only, `freewill=true`, owner online).
  - The bridge accepts it only when Goblin is following or already doing
    free-will work, so explicit orders are never overridden.
  - Free-will work is recalled to FOLLOW on a threat, or when the owner walks
    more than `GoblinGoalRecallDistance` away.
  - Scripted chores wait `GoblinFreewillGraceSeconds` for Qwen before filling in.
  - `/goblin freewill on|off` toggles it (on by default).
- **Memory** (`goblin_zomboid/mind.py`, `*.mind.sqlite3`):
  - Episodes (the last 400 per Goblin), visited rooms with notes like "nearly
    died here", and a daily journal. Qwen refines the journal; a heuristic
    entry is written first.
  - Trust in the owner rises with thanks, praise, apologies and finished work,
    and falls with insults, hordes and the owner getting hurt.
  - A digest goes into every chat and free-will prompt.
- **Proactive talk**: free-will turns may be pure speech (questions, complaints),
  and they reuse the owner's conversation history.
- **Goblin meetups**: when two different owners' Goblins are within 12 tiles
  and both are idle, Qwen writes a 2–4 line exchange, spoken 4 s apart. Each
  pair has a 10-minute cooldown, and both remember the meeting. This is talk
  only: no items change hands.

Live checks are in the runbook, section 6c.

### Goblin Sentience V1, 2026-09-28

Owner direction: Goblins should feel like fellow players, not a job picker.
A persistent cognitive layer (`goblin_zomboid/sentience.py`) now sits between
perception and the unchanged action path (validator, safety, bridge, Lua):

- **A continuous self** per Goblin, saved in `*.mind.sqlite3` (`self_state`):
  mood, desires with priorities, current goal (with reason), a plan of 1-6
  steps, a suspended goal, private thoughts and expectations.
- **Event-driven cognition.** The situation log plus derived changes (owner
  hurt or bitten, horde or rising threat, job complete/failed, night coming,
  left base, new place, another Goblin met, food low, car in bad shape, owner
  praise/insult) are weighted 0-1. Anything at 0.5 or more wakes a reflection
  at once (at most every 20 s per Goblin); otherwise he reflects every ~4 min.
  Reflection runs while he follows a moving owner; physical free will still
  waits for the owner to stop.
- **Reflection** (`QwenClient.propose_reflect`, strict JSON schema): continue,
  new, interrupt (old goal suspended and resumed after), complete or abandon;
  a plan whose steps must be known intents; mood; a private thought; up to
  three opinion updates; an expectation; and an optional line to say.
- **Plans drive actions.** The physical free-will turn receives the current
  goal and step and performs it; the game's job result advances the plan, and
  a failure wakes a rethink. Owner orders never advance or cancel the plan.
- **Opinions** (`opinions` table) about the owner, places, other Goblins and
  activities drift from events and reflections (never jump).
- **Salient memory.** Episodes carry importance, feeling, place and people.
  Prompts get recent memories plus the most significant ones and those tied
  to the current place and people; significant memories outlive routine ones.
- **Private by default.** Most thoughts are never spoken; he speaks up when a
  thought matters (importance 0.6+) or now and then, never repeating himself.
- Chat also sees his mood, goal and opinions, so he can explain himself.
- Admin snapshot: `sentience` shows each Goblin's mood, goal, plan and thoughts.

### Furniture salvage

Owner direction, 2026-09-27: Goblin also breaks up furniture for planks and
other materials by himself. `DISMANTLE` has a salvage mode:

- **What he scraps:** the nearest empty, single-tile wooden furniture within
  `GoblinSalvageRadius` (24) tiles. He never touches player-built objects.
- **Where he won't:** anything outdoors, inside the saved base or within
  `GoblinSalvageBaseBuffer` (6) tiles of it, or in any safehouse (including
  the owner's own). Protection is re-checked just before the scrap.
- **What he gets:** vanilla's moveables scrap rules decide what drops. Goblin
  then picks it up through the audited pickup path, so planks, nails and the
  rest are real items.
- **When it runs:** the idle chore loop triggers it when base windows need
  boards and no planks are at hand (only while the owner is online). Qwen's
  free will can choose `DISMANTLE` with `job: salvage`, and the owner can use
  `/goblin salvage` (or `scrap`).
- **Turning it off:** `GoblinSalvageEnabled=false` disables it; the explicit
  `dismantle furniture` order inside the base is unchanged.

### Locked gate route, 2026-09-27 (server passes, two-client observation pending)

Three disposable-server runs of `Milestone3GateRouteProbe` (13:31, 13:38 and
13:43 local) ended `terminal=COMPLETE success=true crossed=true open=true
padlocked=false key_id=-1 key_consumed=true returned_padlocks=1`, then cleaned
up. Both clients logged `target_missing=true` for every phase, so the
two-client half of the gate is still open. The observer searched client-side
`modData.GoblinNPC/GoblinOwner`, which the server never replicates, so it could
not find the Goblin regardless of the gate. The probe now sends the Goblin's
native online ID, and the observer matches on that, or on the client-side
`GoblinID` variable. It also logs `gate_found`/`goblin_found` when a phase is
missing. The probe also waits for a coherent actor square and sends the
server-built gate with `transmitAddObjectToSquare` before any lock packets.

## Remaining work

| Milestone | What remains |
| --- | --- |
| 3 — Tools and access | Live gates only: locked-gate two-client rerun, window breach, alternate entrance, fence/gate after restart, vehicle two-client, interruption/restart, safehouse. |
| 4 — Base and logistics | Live: managed-actor custody for each new job, second-client item-ID agreement, save/restart reconciliation, native repair on IsoZombie. |
| 5 — Survival | Live: chop, bandage, forage, traps and cook with the managed actor. Not implemented: fishing (B42 fishing is a client-side rod/bobber minigame), barbecue/fireplace cooking, picking traps back up, clothing patching (tailoring rips are hand-craft recipes via `CRAFT`), construction beyond crate/wall/fence. Farming covers plow/sow/water/harvest/tend. |
| 6 — Vehicle service | Live: every adapter, `getSqlId` restart resolution, recipe-free brakes, in-place battery charging. |
| 7 — Reflex Brain | The shipped Naive Bayes classifier and canned outage replies are only a routing/fallback scaffold, not the V2 tiny dialogue-generation model. The requested 3–15M encoder/decoder (or a justified replacement), 25–50K-pair training corpus, `.76` latency test and outage drill remain. Per owner direction, Qwen stays the primary Lenin/Stalin conversational voice, so this is optional; training the tiny model needs GPU hardware and a corpus build that were not available here. |
| 8 — Goals | Live: interrupt/resume and restart. |
| 9 — Offline Life | Blocked by the engine: with no player online, the cells around the base unload and zombie actors (Goblin included) are not simulated. Offline chores need a zero-player simulation proof first. Existing bounded offline grants (WAIT, LOOT_AREA, RETURN_TO_BASE, SECURE_BASE, EQUIP) are unchanged. |
| 10 — Experimental driving | Deferred. |

## Latest validation

September 27 (later): 685 automated tests; two expected failures and one
art-asset error. Python compilation, JSON parsing and the catalog consistency
check pass. Conjured supplies are restored by owner direction (the earlier
review had removed them). These results validate code and fixtures,
not the live gates listed above.

September 26 container checkpoint: ordinary-container approach was observed
on two no-Storm clients with matching actor/outfit and unchanged empty contents;
an actual server save/restart resumed the same ordinary-container target.
Native keyed-container compatibility also passed on the managed IsoZombie
(matching real key retained, padlock retained). Keyed-job movement/replication
and nonempty transfers remain separate unverified gates. See
MILESTONE3_CONTAINER_CHECK.md. Current local packages contain 171 source files;
the 170-file provenance record below is historical.

- Earlier checkpoint: 551 tests passed with two existing expected failures
  before the September 27 implementation additions.
- Access suite: 36 tests pass, covering direction, restored crossings, reclosed
  doors, removed targets, revoked access and native unlock failures/group retries.
  Direction/restoration, permission and unlock regressions failed before their
  fixes. Actual server save/reload is pending. The unlock hardening is now
  loaded locally; one real matching-key door test passed with key retention
  and both clients observing the lock/open transition. A later CustomLock
  no-key test preserved the locked door and completed via an alternate window.
  That run exposed mismatched lock flags between clients; lock/window
  replication, multi-panel failures and other access paths remain open.
- Catalog: 64 records pass consistency checks.
- Fishing registry resolution now distinguishes the factory's verified
  `Base.WaterBottleEmpty` → `Base.WaterBottle` fallback from the still-unresolved
  `Base.WoodenStick` break-rod replacement. No fishing ability is inferred.
- LOOT transfer follow-up reproduced the square-less `ItemStats` failure at
  `Food.updateAge` from managed IsoZombie inventory removal. A candidate now
  uses installed `ItemContainer.DoRemoveItem` (which bypasses that callback).
  Installed bytecode confirms the destination `AddItem` assigns its container
  before `Food.OnAddedToContainer -> Food.updateAge`; a floor drop assigns an
  addressable world-item square. Callback ordering is confirmed, but the exact
  managed-actor transfer, packet result, second-client item identity and
  save/reload remain unverified, so LOOT remains incomplete. The 171-file direct
  local package passed exact SHA-256 preflight and loaded; a no-Storm client
  connected to the local login queue, but `runtime.state` remained at
  `player_count=0` with no Goblin actor. This is package/load evidence only,
  not transfer acceptance.
- A subsequent one-client native check reached a real doorway's intended
  interior side. A follow-up closed-door test recorded reopening and crossing,
  and both no-Storm clients independently observed the live close/open state
  changes. The later matching-key test also replicated both lock flags. See
  MILESTONE3_EXISTING_BUILDING_CHECK.md; missing-key/breach/gate,
  continuous client movement and save/reload acceptance remain open.
- The current source changes have not been deployed to .03 or Steam Workshop.

## Local test provenance correction

The September 26 restart exposed stale `0.5.0-dev` packages in both isolated
client caches while the server used the current `0.6.0` package. That run cannot
certify current-source behavior. Both direct and Workshop copies in client
caches 10 and 11, plus the server direct copy, now match all 170 source files
by SHA-256 and exact file set. The 44 obsolete files in each old client package
were moved to `C:\Users\tomgr\Zomboid\goblin-test-backups\stale-test-package-20260926`
for recovery. Production and the published Workshop package were not changed.

The restarted server and both clients subsequently ended; no new in-world
acceptance is claimed. Before the next live test, run the read-only preflight
against the server package and both package locations in each client cache:

```powershell
python -m tools.check_pz_test_package --package-dir '<installed package directory>'
```

Repeat `--package-dir` for each copy. Missing, changed, extra, empty or absent
packages fail the check. Its two focused tests pass. Package identity is a
prerequisite for a live test, not evidence of working gameplay.
