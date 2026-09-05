# Multiplayer survivor authority

## Authority model

The dedicated PZ server is the logical authority for every managed survivor.
It owns stable identity, generation, profile, protection, task/job state,
follow targets, movement, hostile-zombie combat, persistence, and bridge
validation.

Connected clients do not issue movement decisions or write survivor state.
They receive a bounded `client_survivor` snapshot and create local
`HumanSurvivor` Java render actors. This actor is not a player and is not sent
through the vanilla zombie entity stream.

## Snapshot contract

- `actor_id` is stable and is never replaced by a display name or object
  pointer.
- `generation` identifies a death/recreation body replacement.
- `sequence` is strictly increasing; stale packets are ignored.
- The server position is authoritative. The client reconciles its local
  visual body to that position and never sends a position claim.
- The snapshot carries the deterministic visual profile, including Goblin's
  fixed `Spike` hair and the managed firearm profile.
- Exact tracker telemetry is kept separate from the coarse runtime state.

## Lifecycle rules

On first usable player position, the server creates the bounded roster. On
client join, every roster member is retried independently until its local
visual exists. On generation change, the client removes the old actor before
creating the replacement. On absence, pending retry state is cancelled.

Server-side unload/rebind, reconnect, duplicate prevention, and two-client
parity still require live acceptance tests.

## Local matrix

The completed single-client checks include visible human creation, Goblin
follow movement, ranged combat against a hostile zombie fixture, and Goblin
death/recreation. The parallel-client probe used an isolated cache but reused
the first username and was rejected, so the two-client gate remains open.
Repeat it with two distinct non-Steam usernames before any release decision.
