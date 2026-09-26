# Existing-building access check — 2026-09-26

## Scope and provenance

Disposable `goblin-local`, Build 42.20.4, server PID 2524 with server-side
Storm; ordinary no-Storm client PID 11680, user `m3witness_54`.
All 170 package files matched source before staging a single local-only probe.
The probe used `Brain.setTask(GAIN_ACCESS)` and the normal Jobs/selector path.
It did not modify geometry, locks, keys, inventories or actor positions and
explicitly disabled breach. This tests the backend, not chat-command delivery.

Source checkpoint: `abcd280`, plus the unmodified gameplay package and
`tools/probes/Milestone3ExistingBuildingProbe.lua`.

SHA-256:

- GoblinAccess.lua: `9bde9928008e221f7fb7e37337e9845473a1380f10568733eef015d70c937b08`
- GoblinGainAccess.lua: `53ddaa6d54b370b5925f0f745a73c08b8fcd05479bc67bf8648f25cd699e5f71`
- goblin-server.jar: `e5c3c617a7e4043f0b1190ced6f6badc79c4ec674aaf117f1fe44cf324a1410f`
- Probe: `d9a4af3d3edbc1f4d0fe69bd42ad5c2e0af5278929fbe3a61261f2d34ffd0516`

## Observed result

The real selector chose a DOOR edge at `(10779,9767,0)`, offset `(0,1)`,
destination side 1. The logs recorded:

| Server tick | Position | Result |
| --- | --- | --- |
| 443 | — | Dispatch accepted: least-destructive door method |
| 446 | 10788.848, 9774.106, 0 | Walking to open access edge |
| 488 | 10783.069, 9769.5, 0 | Walking to open access edge |
| 527 | 10779.501, 9767.508, 0 | COMPLETE: reached building interior |

Normal command completion returned to FOLLOW. The client screenshot displayed
`Ratspit Plankgobber: Comrade, reached the building interior.` The observer
restored the original Jobs.update function and logged `cleanup=true`.

The full local log snapshot is retained at
`C:\Users\tomgr\Zomboid\goblin-test-backups\m3-existing-building-20260926.stdout.log`.
The staged probe and enabling flag were removed after completion. The probe
source remains outside the mod package for repeatable disposable tests.

## Limits

This supports selection and completion at the intended interior side of an
existing open doorway. Server coordinates update in coarse jumps in this
trace; it does not independently prove uninterrupted animation or absence of
navigation recovery. There is no before/after closed-door state measurement.
The completion message alone is not physical proof; the positional trace is
the additional evidence, and a direct visual crossing still needs capture.

Only one client was connected for this probe. A previous two-client startup
spawned one Goblin per account, but its second client exited before the order.
No second-client replication, material consumption, locked entrance, breach,
fence/gate traversal or save/reload acceptance is claimed. Milestone 3 stays
open. No production, main-branch or Workshop deployment occurred.
