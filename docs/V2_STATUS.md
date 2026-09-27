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
`LIVE_ACCEPTANCE_RUNBOOK.md`. Registry: 22 capabilities.

| Milestone | Added | Key design points |
| --- | --- | --- |
| 4 | Storage categories (`storage CATEGORY`), `SORT_STORAGE`, `FETCH_ITEM`, `DELIVER`, `REPAIR_STRUCTURE`; `MAINTAIN_BASE` now chains native repairs after boarding | A primitive per-item ledger (native item ID) is persisted in the task payload and reconciled after interruption or restart. Full-container fallback: same category, then OVERFLOW, then back to source. Cold-storage food is never removed. Repair uses the installed `ISMoveableSpriteProps` eligibility, parts and chance. Parts leave through server custody (no actor-inventory packet). |
| 5 | `CHOP_WOOD` (IsoTree.WeaponHit), `TREAT_PLAYER` (BodyDamage.SetBandaged) | Real axe and real bandages only. Cooking, tailoring, fishing, trapping and foraging stay unregistered. |
| 6 | `VEHICLE_INSPECT`, `REFUEL_VEHICLE`, `INSTALL_PART`, `REMOVE_PART`, `REPLACE_PART`, `CHANGE_TIRE`, `VEHICLE_SERVICE` | Vanilla install tests need `getPlayerNum`, so they are re-evaluated server-side. The mechanic key rule, `requireInstalled/Uninstalled`, the engine-door open/close and recipe/profession/trait gates are enforced. Recipe-gated parts (for example brakes) are refused because Goblin has not learned Basic Mechanics; this needs a product decision. Battery charging via a charger is not implemented; use `replace Battery`. |
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

Reusable tools come from Goblin's persistent toolkit. Consumables and building,
crafting, medical, farming and vehicle materials are never fabricated: jobs must
find and consume real installed items or report `MISSING_MATERIAL`.

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
| 5 — Survival | Live: `IsoTree.WeaponHit` and `SetBandaged/syncBodyPart` with the managed actor. Remaining adapters (cooking, tailoring, fishing, trapping, foraging, broader construction, full farming lifecycle) are not implemented. |
| 6 — Vehicle service | Live: every adapter, `getSqlId` restart resolution, recipe-gate decision, charger-based battery charging. |
| 7 — Reflex Brain | The shipped Naive Bayes classifier and canned outage replies are only a routing/fallback scaffold, not the V2 tiny dialogue-generation model. The requested 3–15M encoder/decoder (or a justified replacement), 25–50K-pair training corpus, `.76` latency test and outage drill remain. Per owner direction, Qwen stays the primary Lenin/Stalin conversational voice. |
| 8 — Goals | Live: interrupt/resume and restart. |
| 9 — Offline Life | Prove zero-player simulation, then design bounded offline chores. |
| 10 — Experimental driving | Deferred. |

## Latest validation

September 27 source review: 633 automated tests pass with two expected failures;
Python compilation, JSON parsing and the 64-record catalog consistency check all
pass. The review removed a candidate supply-fabrication path so every material
adapter again requires real items. These results validate code and fixtures,
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
