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

## Subsequent keyed-door check on fe712ab

Server PID 18464, clients PID 7388 (`m3path_61`) and 32680 (`m3witness_54`),
both no-Storm. All 170 gameplay files matched fe712ab in the five local
package locations. GoblinAccess.lua hash for this newer run:
`6d301eb2b0717ea548883987f510efb0b2d5f2d387909c28eb5974771c8a38ae`.
Other gameplay hashes above remain unchanged.

The explicitly selected `keyed-selected-door` fixture closed/locked only the
ordinary selected door and supplied one actual `Base.Key1` with native key ID
15871650. Both test players were initially placed outside; no Goblin position
was forced. The route was selected before locking, so this remains a mutation/
revalidation test, not a route-ranking test among initially locked entrances.

- Tick 704: fixture locked; Goblin at `(10779.433,9773.523,0)` with matching key.
- Ticks 705–735: real approach with open=false, locked=true, key_locked=true.
- Tick 738: OPEN_ORDER_DONE.
- Tick 741: exterior side `(10779.413,9768.581,0)`, open=true and both locks=false.
- Tick 744: COMPLETE at `(10779.454,9767.798,0)`, intended interior side.
- Cleanup: original open/lock/key-ID state restored; matching key retained
  before cleanup=true; exact fixture key removed=true; task wrapper restored.

Independent client observations (timestamps in ms):

| Client | Closed and both locks true | Open and both locks false |
| --- | --- | --- |
| m3path_61 | 1790453742910 | 1790453745927 |
| m3witness_54 | 1790453742485 | 1790453746002 |

This verifies actual native key presence/retention, lock mutation, interior
arrival and live lock/open replication with the readback fix loaded. A normal
door key is reusable, so retention is the expected conservation result. No
consumable-material operation is involved. This is not a live missing-key
denial, grouped-panel failure, padlock removal, alternate-route or save/reload
test. Those gates remain separate.

Probe SHA-256:

- Server: `81129463dff1bbf80aa119ae6193ebca00df337420793f27e86f9d26d81f470c`
- Client: `09b27908cf3a8b2c68bd4881c98ee49c590092d2fa3ff61cbffa1b66bbf7f013`

Raw logs are retained at
`C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-door-20260926.`
with suffixes `server.log`, `client10.log`, and `client11.log`.
All staged probe files and enabling flags were removed after the run.

## Missing-key CustomLock and alternate-window check on 4bb2e8a

Server PID 3156; no-Storm clients 42664 (`m3path_61`) and 36804
(`m3witness_54`). Gameplay files are unchanged from the keyed-door run.
The selected ordinary front door was locked after preparation, with its native
CustomLock modData set true and no matching key supplied. This tests execution
revalidation, not selection among initially locked entrances.

- Tick 1286: fixture applied; Goblin at `(10788.432,9773.358,0)`.
- Tick 1288: locked front door rejected; alternate back-door route selected.
- Back-door approach did not reach its target within the approach budget.
- Tick 1744: bounded fallback selected the window at `(10782,9762,0)`.
- Tick 1801: native window opening recorded.
- Tick 1810: COMPLETE at `(10782.979,9762.5,0)`, intended interior side.
  Original front door remained closed with both locks true; matching_key=false.
- Cleanup logged fixture_restored=true and returned Goblin to FOLLOW. The
  probe restored CustomLock, original lock/key ID and open state. No key or
  consumable was created. No Goblin position was forced.

Both clients observed the original door closing and reopening during cleanup.
Client10 recorded both lock flags true at timestamp 1790454591538; client11
recorded both false at 1790454591584. Thus server-side lock preservation and
successful alternate entry are proven, but this run does **not** pass two-client
lock replication. The observer did not monitor the alternate window, so its
replication also remains unverified. Back-door path efficiency remains a gap.

Earlier no-key fixtures without CustomLock were not valid denial tests:
the opening trace showed square `(10779,9768)` had exterior=false. Installed
`media/lua/shared/TimedActions/ISLockDoor.lua` permits keyless unlocking from
such a square, but explicitly denies it for CustomLock without the key.
No gameplay behavior was changed to satisfy that incorrect test expectation.

Server probe SHA-256:
`440ad08111db7077920bde91a7beada6442bb6472c58dd25b2548b80b82eb66d`.
Client observer hash remains `09b27908cf3a8b2c68bd4881c98ee49c590092d2fa3ff61cbffa1b66bbf7f013`.
Raw logs: `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-customlock-20260926.`
with suffixes `server.log`, `client10.log`, and `client11.log`.
Staged probes and flags were removed after terminal cleanup; source probes
remain under tools/probes, outside the released package.
