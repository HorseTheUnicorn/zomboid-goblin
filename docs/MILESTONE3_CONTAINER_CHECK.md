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
