# Multiplayer survivor authority

## Authority model

The dedicated PZ server is the logical authority for every managed survivor.

The server owns:

- stable survivor identity and body generation;
- profile and protection capabilities;
- brain goal and serialized task queue;
- perception decisions and hostile-target arbitration;
- native path requests and combat intent;
- persistence and rebind decisions;
- Qwen semantic-intent validation at the bridge boundary.

Clients do not issue movement decisions and do not write server state. In the
current Build 42 slice they receive a bounded GoblinSurvivor state packet and
create a local `IsoSurvivor` render actor. The actor is never an `IsoZombie`
and is not sent through the vanilla zombie packet stream.

## Physical body modes

The default local mode is `client_survivor`. The dedicated server owns the
logical position and follow state; each connected client creates an
`IsoSurvivor` from the snapshot and reconciles its local position. This is the
verified way to render a human actor because the installed B42 multiplayer
protocol has no vanilla `IsoSurvivor` network packet.

`native_zombie` remains only as a legacy experiment. It uses a fully
networked `IsoZombie` donor, and `IsoZombie.setAsSurvivor()` changes clothing
only; it does not change the entity class or zombie AI. The Storm bridge is
disabled in the default client-survivor mode so it cannot create that donor.

## Reconciliation rules

- An actor is keyed by stable `actor_id`, never by display name or a temporary
  client object pointer.
- Snapshot `sequence` values are strictly increasing and stale packets are
  ignored.
- Server state is the position authority; clients do not send position writes.
- In legacy `native_zombie` mode, a pending spawn reservation may claim only
  one body near its reserved point and normal zombies are never claimed
  without a matching reservation or complete managed identity markers.
- A valid vanilla zombie player target is preserved. Survivor target selection
  is an opt-in, bounded arbitration path.
- If the brain is malformed, the server clears the queue and enters safe idle;
  it does not crash the server or modify unrelated zombies.

## Release test matrix

The local MP gate must cover one and two clients, players in the same and
separate areas, join/disconnect, server restart, cell unload/reload, duplicate
body prevention, and consistent state/visual observation. Production is not a
development test harness; `.03` is touched only by an explicit release
deployment after this matrix passes locally.
