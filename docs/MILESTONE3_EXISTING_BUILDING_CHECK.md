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

## Subsequent closed-door and two-client replication check

These later results extend, rather than replace, the original run above.
Gameplay source hashes remain unchanged. The updated probe has an explicit
`close-selected-door` fixture mode and an optional second-player readiness
gate. It refuses locked/barricaded or multi-panel fixtures, closes the selected
ordinary door before the first job tick, and restores the original state after
completion. It does not establish *selection preference* among closed routes.

First, server PID 19180 / no-Storm client PID 41832 recorded door_open=false
during approach, OPEN_ORDER_DONE at tick 528, door_open=true on the exterior
edge, and COMPLETE at `(10779.5,9767.5,0)` at tick 567. Fixture restoration
and observer cleanup both succeeded. Raw log:
`C:\Users\tomgr\Zomboid\goblin-test-backups\m3-closed-building-20260926.stdout.log`.
That intermediate probe hash was
`8f90e54240dc7bd1302400cc36ee439d4f553ab54fba60a414776fca7eb28480`.

The following run used server PID 8860 and no-Storm clients PID 11896
(`m3path_61`) and PID 42572 (`m3witness_54`). A temporary client observer
placed the second TEST PLAYER beside the house using vanilla `teleportTo`;
no Goblin position was set by either probe. All 170 gameplay source files
matched in all five installed package copies; only named test probes were
additional. The server waited until both players were nearby for 20 seconds.

- Server tick 553: accepted normal GAIN_ACCESS; fixture confirmed closed.
- Tick 748: OPEN_ORDER_DONE; Goblin at `(10779.468,9768.442,0)`, door open.
- Tick 754: COMPLETE at `(10779.492,9767.671,0)` on the intended interior side.
- Both fixture restoration and observer cleanup returned true.

Independent native client `door:isOpen()` observations (timestamps in ms):

| Client | Initial open | Fixture closed | Goblin reopened |
| --- | --- | --- | --- |
| m3path_61 | 1790453050358 | 1790453069492 | 1790453089161 |
| m3witness_54 | 1790453049386 | 1790453069877 | 1790453088960 |

Both clients were loaded at the door **before** the close/open transitions;
this is live door-state replication evidence, not just reconnect visibility.
Post-test screenshots showed both players and named Goblins in the same house.
The client observer did not resolve Goblin identity from modData, so it produced
no usable client-side Goblin coordinate trace. Server movement remains the
positional evidence. Players moved during the run beyond the explicit fixture
placement; this is not an isolated, input-free motion benchmark.

Probe hashes for this run:

- Server probe: `14cbb10ef3f5a13ed8244096c4866b40fa073a9b6ae2b5f43ed49fdd16e5f069`
- Client observer: `80459ae7caf2d49f9aff8c0ff2c94038370a7dc857e7acb25b9df9a0e2c99e0e`

Full logs are retained under
`C:\Users\tomgr\Zomboid\goblin-test-backups\m3-door-replication-20260926.`
with suffixes `server.log`, `client10.log`, and `client11.log`.
All staged probe files and flags were removed afterward. The bounded client
observer stops sampling after 180 seconds; the server job wrapper was restored.

Ordinary selected-door reopening and live door-state replication now have
current-build evidence. This still does not certify locked/keyed entrances,
alternate-route preference, breach, gates, material/key conservation or
in-progress save/reload. Milestone 3 is not yet complete.
