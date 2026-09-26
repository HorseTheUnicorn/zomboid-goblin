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

## Remaining work

| Milestone | What remains |
| --- | --- |
| 3 — Tools and access | Finish native compatibility gaps and current-build live tests for alternate entrances, window breach, fences/gates and vehicle access. Verify material/key transfers and save/reload. Ordinary-door reopening/interior arrival has server positional evidence and live door-state replication observed in both no-Storm clients; continuous client movement capture remains pending. |
| 4 — Base and logistics | Complete structure repair, storage categories/sorting and fetch/deliver workflows. Inspection, window boarding and stockpiles have partial implementation and earlier user-observed tests; finish current-build conservation, interruption and replication checks. |
| 5 — Survival | Complete supported construction, farming improvements, cooking, medical, tailoring, woodcutting and feasible foraging/fishing/trapping adapters against installed native behavior. Item existence alone does not establish support. |
| 6 — Vehicle service | Complete inspect/service, fuel, battery, tires and part removal/installation with real materials and replication. Existing transport, unlock/start and repair paths are a foundation, not completion of this milestone. |
| 7 — Reflex Brain | Implement the social-only router, original dataset generator, training, small CPU model and Qwen fallback. Resolve the recorded Qwen capability/context gaps and prove that model output cannot expand gameplay authority. |
| 8 — Goals and autonomy | Add persistent multi-step goals, priorities, maintenance cycles and failure-driven replanning through verified capabilities. |
| 9 — Offline Life | Establish the verified zero-player simulation mechanism, bounded loaded work area and real offline chores with reconciliation. Do not infer physical work from a persistent identity or queued intent. |
| 10 — Experimental driving | Implement and test only after preceding milestones are stable. |

Each ability still needs observed movement, material consumption, world changes,
multiplayer replication and relevant persistence/rollback evidence before it is
marked complete. Unsupported native operations must remain explicitly identified.

## Latest validation

September 26 container checkpoint: ordinary-container approach was observed
on two no-Storm clients with matching actor/outfit and unchanged empty contents;
an actual server save/restart resumed the same ordinary-container target.
Native keyed-container compatibility also passed on the managed IsoZombie
(matching real key retained, padlock retained). Keyed-job movement/replication
and nonempty transfers remain separate unverified gates. See
MILESTONE3_CONTAINER_CHECK.md. Current local packages contain 171 source files;
the 170-file provenance record below is historical.

- Full automated suite: 537 tests run successfully, two existing expected failures.
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
- LOOT transfer follow-up reproduced the square-less `ItemStats` failure at
  `Food.updateAge` from managed IsoZombie inventory removal. A candidate now
  uses installed `ItemContainer.DoRemoveItem` (which bypasses that callback);
  80 focused work tests pass. Perishable age, two-client item identity and
  save/reload remain unverified, so LOOT remains incomplete. The current
  171-file direct local package passed exact SHA-256 preflight and loaded on a
  server-only startup; that server had no actors (no connected client), so this
  is a package/load smoke check, not transfer acceptance.
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
