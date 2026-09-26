# Goblin Abilities V2 checkpoint — 2026-09-26

The full V2 specification is not complete. This checkpoint preserves the accepted
companion foundation and distinguishes implemented code from live acceptance.

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
| 3 — Tools and access | Finish native compatibility gaps and current-build live tests for alternate entrances, window breach, fences/gates and vehicle access. Verify both clients, material/key transfers and save/reload. The new interior-side correction has automated tests only. |
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

- Full automated suite: 534 tests run successfully, two existing expected failures.
- Access suite: 35 tests pass, covering direction, restored crossings, reclosed
  doors, removed targets and revoked access. Direction/restoration and permission
  regressions failed before their fixes. Actual server save/reload is pending.
- Catalog: 64 records pass consistency checks.
- No new physical access acceptance was obtained in the latest local run.
- The current source changes have not been deployed to .03 or Steam Workshop.
