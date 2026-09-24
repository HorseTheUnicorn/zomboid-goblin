# Milestone 2 — capability framework closeout

Status: complete for the framework scope, 2026-09-24. The user accepted the
earlier local tests and requested completion without repeating follow tests.
This is not completion of all V2 abilities or a production release.

## Requirements

| Specification requirement | Implementation and evidence |
| --- | --- |
| Additive capability registry | `GoblinCapabilities.lua` owns registration, policy descriptors, preparation, update, cancellation, requirements and snapshots. `GoblinJobs.lua` adapts nine handlers without replacing their native implementations. |
| Structured job results | Canonical done/success/code/detail/progress results, standard failure codes, exception containment and bounded timeout. Jobs saves the primitive result for external reasoning. |
| Preserve existing handlers | Adapter regression tests cover curtains, farming, crafting and vehicle repair, including material consumption, target revalidation and cancellation. Earlier user-accepted live tests are retained; they are not represented as fresh tests of every current adapter. |
| Serializable semantic payload | Prepared payloads and snapshots reject engine objects, functions, cycles and nonfinite values; copied values prevent mutation across the boundary. Engine references remain runtime-only. |
| Safe terminal behavior | Terminal success, failure and malformed-result handling are latched until clear/cancel. Duplicate updates cannot replay physical side effects; an explicit new job can run normally. |

Registered adapters: CLOSE_CURTAINS, CRAFT, DISMANTLE, FARM, GAIN_ACCESS,
INSPECT_BASE, MAINTAIN_BASE, REPAIR_VEHICLE and STOCKPILE. Registration does
not establish that every operation in an adapter is supported by IsoZombie.
Current adapters retain server authority and online-owner requirements;
offline physical work remains a separate milestone.

## Validation

- Full suite after the terminal guard: 520 tests, two expected failures.
- Focused framework/handler checks cover registry policy, primitive payloads,
  strict results, exception handling, cancellation, copy isolation, material
  refusals and terminal replay prevention.
- Disposable server live SawLogs job: one actual Base.Log consumed, three
  Base.Plank produced; WORKING transitioned to COMPLETE. A duplicate registry
  update returned COMPLETE with inventory unchanged. The ordinary no-Storm
  client displayed Plank (3) on the ground after delivery.
- Live trace: `C:\Users\tomgr\Zomboid\Logs\m2-craft-terminal-20260924.stdout.log`,
  completion at st=513509449. Registry source SHA256:
  `26f6b7aef7eeb83152120bb4a2b08663f450790aa2292116bed651e11163c11b`.
- Temporary staged server probe and opt-in flag removed after the check;
  reusable probe remains outside the release mod tree.

## Boundaries and next milestone

The second client was connected but did not inspect this new craft output;
reload persistence was not retested. These are per-ability evidence gaps,
not claims of successful verification. The historical four-adapter acceptance
JSON and its strict source-hash validator remain historical: this closeout
does not rewrite their hashes or convert old tests into current-build proof.

Follow/navigation is user-accepted and should not be rewritten as part of
Milestone 2. Next is Milestone 3, tools and access, starting from the existing
implementation and its outstanding evidence rather than reimplementing it.
Production .03, GitHub and Steam Workshop have not been changed by this work.
