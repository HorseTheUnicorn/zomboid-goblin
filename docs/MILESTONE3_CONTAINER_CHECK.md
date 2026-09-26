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
