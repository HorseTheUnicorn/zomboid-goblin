# Milestone 3 native container access — September 26, 2026

Candidate 08d18a3, disposable goblin-local server PID 32120 with server-side
Storm; no-Storm client PID 51608, account m3path_61. The test client fixture
placed only the player at `(10779.5,9765.5,0)` in an existing house. The server
probe dispatched normal Brain.setTask GAIN_ACCESS with target.kind=CONTAINER.
It did not force Goblin positions, select a fabricated object or alter contents.

- Tick 418, st 745025820: dispatch=true, accepted=true.
- Tick 419: selected object marker `m3path_61:1790456645495:1`, contents read
  successfully; Goblin `(10779.546,9769.483,0)`, MOVING_TO_TARGET.
- Tick 467: `(10780.326,9765.477,0)`, still moving.
- Tick 506, st 745034619: COMPLETE at `(10779.158,9766.237,0)`.
- Same tick: terminal_contents_unchanged=true; cleanup=true, wrapper restored,
  and normal FOLLOW restored. Contents comparison used sorted native item IDs.

This establishes normal task dispatch, native movement/arrival and unchanged
contents for an accessible real container. It is not a locked-container/key
trial, a client-visible inventory replication test, a two-client movement
observation, or persistence/reload acceptance. Container access deliberately
does not imply looting or lock removal. No physical access milestone is closed.

Source SHA-256:

- GoblinContainerAccess.lua: `71090a88ad173c59f24107d8165ff3160f69806fafdacb246f3d9f67b5783bfc`
- GoblinGainAccess.lua: `c6f314e8451b99950ead40112fb8548f5fe9d10645563c8bc14debe1c113e83b`
- Server probe: `77aa2aa7d66e68b9650ef54e7009516162cacf940c90cb710490cd21768c514d`
- Client placement: `de7399c5a8d17efa38fe4f98d35fbf8abef9602b3c40d4cc482a4f2d9e352c24`

Raw logs retained under
`C:\Users\tomgr\Zomboid\goblin-test-backups\m3-container-access-20260926.`
with `server.log` and `client10.log` suffixes. Staged probes and flags were
removed after completion. The ordinary container identity marker created by
the adapter remains, as intended for task persistence. Local server/client
remain running; production, main and Workshop were not changed.

## Actual save/restart/resume check on 72d102e

The disposable profile originally had SaveWorldEveryMinutes=0. It was
temporarily set to 1 for the save phase, then restored to 0 before the resume
server started. This was not a simulated Lua-table reconstruction.

Save phase: server PID 54932, no-Storm client PID 42764.

- Tick 377: normal GAIN_ACCESS accepted.
- Tick 379, st 745399842: probe held the task before physical execution and
  saved a primitive content-ID baseline into its payload. Target ID was
  `m3path_61:1790457019269:1`. The hold was bounded to 180 seconds.
- Tick 577, st 745419883–745419927: native SaveAll, Saving GlobalModData,
  Saving finish. global_mod_data.bin was updated on disk.
- Only after that save did the test stop the processes and restart.

Resume phase: server PID 36872, no-Storm client PID 37088.

- The probe in resume mode did not dispatch a task.
- Tick 374: restored_payload=true with the exact same target ID; managed actor
  generation 2 resumed GAIN_ACCESS at `(10779.905,9767.997,0)`.
- Tick 416: COMPLETE at `(10778.627,9765.227,0)`;
  terminal_contents_unchanged=true against the pre-restart payload baseline.
- Normal FOLLOW restored in the running session; probes/flags removed.

This proves task payload, object marker and unchanged container contents
survived a real server restart, followed by actual resumed arrival. It does not
prove other abilities' persistence, a locked-container route, or two-client
replication. With autosave restored to zero, the on-disk disposable checkpoint
still contains the held access task; a later restart can resume that harmless
task again. Terminal-result persistence across a later save is a separate gate.

Probe SHA-256: `bf82f99a66f44b34eff52b937a083172fc3bac24685658b907ff101a7c4c7bc1`.
Logs retained under `C:\Users\tomgr\Zomboid\goblin-test-backups\` as
`m3-container-save-20260926.server.log` and
`m3-container-resume-20260926.server.log`.

## Two-client ordinary-container observation, 2026-09-26

Gameplay source remains ff27620. Server PID 1956; no-Storm clients 43156
(m3path_61) and 43996 (m3witness_54). A failed first-client connection exited;
only that client was relaunched. The witness was subsequently restarted to
load a probe timing correction: its bounded observation starts on the test
message rather than player login. Five focused observer/adapter checks pass.

- Tick 5815: normal GAIN_ACCESS accepted; no direct actor placement.
- Tick 5816: target `m3path_61:1790457019269:1`, initial contents empty.
- Server movement: `(10775.674,9763.854,0)` to
  `(10778.229,9765.230,0)`; COMPLETE at tick 5843.
- Server terminal_contents_unchanged=true; normal FOLLOW restored.
- Both clients independently resolved the same native container marker and
  read empty contents in initial and terminal phases.
- Both independently observed native actor online ID 19009 moving toward
  the destination. At st 746455565/567 their positions were respectively
  `(10778.311,9765.327,0)` and `(10778.563,9765.563,0)`; small interpolation
  differences are retained rather than claimed as identical coordinates.
- Both reported actual outfit 14155840 matching the roster outfit.

This establishes ordinary-container approach and identity/empty-content
observation on two clients. It does NOT establish locked-container handling,
nonempty inventory transfer, or an exhaustive multiplayer access matrix.
Goblin opening locked doors is explicitly intended user behavior; do not
reinterpret this container gate as a requirement to restrict that ability.

Raw logs: `C:\Users\tomgr\Zomboid\goblin-test-backups\` with prefix
`m3-container-two-client-20260926` and suffixes `.server.log`, `.client10.log`,
`.client11.log`. Removed all nine staged probe/flag files after the test;
bounded observers may finish in already-running clients. Source probes stay
outside the shipped mod. No production, main or Workshop changes.

## Native managed-actor keyed-container compatibility

On gameplay source 09ebd5d, disposable server 38648 and no-Storm client
21876 loaded m3path_61. At tick 962, st 746776459, the flag-gated
Milestone3ContainerKeyProbe reported native_result=PASS and cleanup=true.
It used a real unregistered IsoThumpable with a real ItemContainer, following
the installed ISWoodenContainer constructor and native setIsContainer method.
It never registered or replaced world furniture.

The actual managed IsoZombie and real Base.KeyPadlock yielded:

- Padlocked container without matching key: native and adapter deny access.
- Matching key in Goblin inventory: native and adapter allow access.
- Key retained and padlock still set after access checks.
- Nonzero combination code: native and adapter deny access even with key.

The temporary key was removed and the crate remained unregistered. Probe and
flag were removed from the server package afterward. Raw evidence is
`C:\Users\tomgr\Zomboid\goblin-test-backups\m3-container-key-20260926.server.log`.
Lua 5.1 syntax validation passed. This narrows the managed-actor compatibility
gap, but does not establish movement to a keyed crate, content transfers,
replication of keyed access, or saved keyed-job recovery. No door behavior was
changed and no combination-guessing or destructive container method is claimed.

## Two-client keyed-container route, 2026-09-27

Gameplay source remained `2c1e463`. Disposable server PID 32376 ran Storm;
no-Storm clients 51428 (`m3path_61`) and 37224 (`m3witness_54`) used exact
171-file copies of the worktree package. The flag-gated probe created one
temporary native `IsoThumpable` container on the owner's otherwise empty floor
tile, added a real `Base.KeyPadlock` with the matching key ID to the managed
IsoZombie inventory, and dispatched the ordinary `Brain.setTask` GAIN_ACCESS
path. It never moved the Goblin directly.

- Tick 916: accepted target `m3path_61:1790514903214:1` at
  `(10778,9764,0)`. Goblin began at `(10779.972,9767.296,0)`.
- Server samples showed actual movement through `(10779.111,9766.830,0)` to
  `(10778.500,9765.955,0)`.
- Tick 961: `COMPLETE`; `contents_unchanged=true`, `locked=true`,
  `actor_access=true`, and `key_retained=true`.
- Both clients independently resolved the same marker, read an empty container
  with `padlocked=true`, observed online actor ID 5895 moving toward the
  target, and reported actual outfit 14155798 matching the roster outfit.
- Neither client logged `SyncThumpablePacket`, `object index -1`, or a network
  exception during this run.
- Probe cleanup removed only its temporary key and crate; all staged probe and
  flag files were removed. The server and clients were stopped afterward.
- Read-only package checks then reported exact SHA-256/file-set matches for the
  server direct package and both clients' direct and Workshop copies: 171 files
  each.

An earlier disposable run set key/padlock fields before registering the crate.
Build 42 emitted `SyncThumpable` packets with object index -1 and both clients
rejected them. That was a probe-order defect, not a Goblin adapter failure. The
corrected probe registers and transmits the crate before lock setters, matching
the requirement that client replication be error-free before acceptance. The
failed-run logs are retained separately rather than counted as passing evidence.

Raw passing logs:

- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-route-two-client-20260927.server.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-route-two-client-20260927.client10.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-route-two-client-20260927.client11.log`

Probe SHA-256: `1b0a92fd3a8e0b9e3403dc1371aa9e6b54054909d942b980065385720f766256`.
Client observer SHA-256:
`074019b53b683271a9ef6b374081478fa6d7166133911ac965f8488c52a199dd`.
The route proves native managed-actor key compatibility, physical movement,
lock/key/content conservation, and two-client observation for this access
operation. It does not prove inventory transfer or keyed-job save/restart
recovery in that run; the later persistence run below closes that separate
gate. Goblin opening locked doors remains intentional behavior and is not
restricted by this container check.

## Two-client missing-key and code-lock refusal, 2026-09-27

Source `e61f8f6` ran on disposable server PID 41792 with server-side Storm.
Ordinary no-Storm clients 47276 (`m3path_61`) and 32600 (`m3witness_54`)
entered the same running world. A flag-gated server probe created and registered
one native `IsoThumpable` container, placed one real `Base.Nails` item inside,
then exercised Goblin's ordinary `Brain.setTask(... GAIN_ACCESS ... CONTAINER)`
route. The fixture was registered and transmitted before any lock setter could
emit a `SyncThumpable` packet.

- Missing matching padlock key: the normal task returned `accepted=false` with
  `no natively accessible container within five tiles`.
- Nonzero combination code 7419: the same normal task returned the same refusal.
- Both refusals retained the exact prior active task and payload, Goblin
  inventory IDs, content ID 771542329 and native lock state. No fixture key was
  added and no lock or content mutation occurred.
- Both clients independently observed content ID 771542329 at ready and terminal
  phases. They agreed on `padlocked=true, code=0` for the missing-key phase and
  `padlocked=false, code=7419` for the code-lock phase.
- Probe cleanup removed the temporary crate. All eight staged flag/probe files
  were removed, both clients and the server were stopped, and read-only package
  checks reported exact SHA-256/file-set matches for all five disposable
  packages: 171 files each.

Raw passing logs:

- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-container-denial-two-client-20260927.server.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-container-denial-two-client-20260927.client10.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-container-denial-two-client-20260927.client11.log`

Probe SHA-256: `cde0918f59c30d569fa2f0a4068b29096076880d12ce5ad0937cbf485a518fb9`.
Client observer SHA-256:
`d42dd276f43068ae6a287b45c9502b184cb41e3384a6eb664cc1af37b69290cf`.
This closes the normal-task missing-key/code-lock refusal gate. It does not
change the explicit access adapter: Goblin opening locked doors is intended
behavior when its authorized route supports that operation.

## Two-client matching-key save/restart/resume, 2026-09-27

The current worktree ran on the disposable `goblin-local` server with
server-side Storm and two ordinary no-Storm clients (`m3path_61` and
`m3witness_54`). A normal
`Brain.setTask(... GAIN_ACCESS ... {target={kind="CONTAINER"}})` selected one
registered native `IsoThumpable` containing `Base.Nails` item ID `1304541578`.
The container remained padlocked with key ID `214660143`; Goblin held the exact
matching real `Base.KeyPadlock` item ID `1083153593`. The fixture was placed on
a same-floor square proven reachable by a bounded breadth-first search rather
than by geometric proximity alone.

The hold phase persisted target marker `m3path_61:1790520022698:1`, exact
content/key identities and the primitive task payload. The probe explicitly
forced Goblin's normal inventory checkpoint, then the native server SaveAll
wrote GlobalModData while the task remained held. Both clients independently
reported the same content ID, `padlocked=true`, and key ID during the hold.

After a full server and client restart, without redispatching the task:

- the same target payload and container marker restored;
- content ID `1304541578`, padlock key ID `214660143`, exact held key item ID
  `1083153593`, and matching-key access all restored;
- Goblin physically resumed `MOVING_TO_TARGET` and completed at
  `(10778.579,9767.754,0)`;
- terminal state retained unchanged contents, the locked padlock, and the key;
- both clients independently observed the same ready and terminal identities;
- cleanup removed the temporary fixture/key, restored FOLLOW, and removed all
  staged probe/flag files; and
- all five disposable server/client direct and Workshop packages again matched
  the 171-file source by exact file set and SHA-256.

Raw passing logs:

- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-persistence-hold-final-20260927.server.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-persistence-hold-final-20260927.client10.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-persistence-hold-final-20260927.client11.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-persistence-resume-final-20260927.server.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-persistence-resume-final-20260927.client10.log`
- `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-keyed-persistence-resume-final-20260927.client11.log`

This closes matching-key container task persistence/reconciliation only. It
does not certify other Milestone 3 routes or destructive container access.
Explicit authorized locked-door opening remains intended Goblin behavior and
is not limited by the non-destructive container rules.
