# Architecture

GoblinSurvivor has three cooperating planes and one authoritative gameplay
boundary.

## Planes

1. The PZ server plane owns the managed roster, server-side Java human actors,
   positions, tasks, combat, persistence, and safety policy.
2. The ordinary PZ client plane receives the bounded snapshot and creates a
   local `HumanSurvivor` visual actor for each roster member. A player client
   does not become the authority for the actor.
3. The `.76` agent plane owns Qwen, Python intent validation, durable memory,
   the filesystem bridge, and read-only tracker telemetry. It has no native
   PZ gameplay client.

The Windows PZ installation is a disposable development harness, not part of
Goblin's production runtime.

## Data flow

```text
PZ server perception/tasks
    -> ServerSurvivorAuthority + ClientSurvivorServer
    -> bounded runtime snapshot
    -> each connected PZ client
    -> local HumanSurvivor visual actor

coarse PZ telemetry -> Python validation -> command.npc_action
    -> server-side Lua validation -> Java authority

exact telemetry -> TrackerStore -> read-only map/history views
```

The bridge is atomic and bounded. The PZ tick never waits for Qwen or the
tracker, and the agent does not receive an unrestricted exact-coordinate body
control API.

## Human actor lifecycle

1. `ClientSurvivorServer.lua` ensures the logical roster exists after a usable
   player position is available.
2. `ServerSurvivorAuthority.java` creates or rebinds a
   `HumanSurvivor`, assigns its stable id/generation/profile, and advances
   authoritative movement and combat.
3. The server publishes a sequence-numbered snapshot containing the bounded
   profile and logical position.
4. `ClientSurvivorActor.lua` creates the local Java human, registers it with
   the cell object/model path, and reconciles newer snapshots.
5. A generation change unregisters the old visual before creating the new one.
   A failed client constructor stays pending and retries without requiring a
   second server packet.

The Java actor extends `IsoLivingCharacter` and implements `IHumanVisual`. It
is neither an `IsoPlayer` nor an `IsoZombie`. Its vanilla update loop is
disabled until a complete NPC lifecycle exists; `tickVisual()` advances only
the safe model/animation path.

## Authority and safety

- The server is the sole position, task, generation, and combat authority.
- Client position writes are not accepted.
- Hostile zombie targets are validated locally and players/friendly actors
  are excluded.
- Goblin protection and the unlimited-ammo policy are reasserted on the
  server actor.
- Test-only fixture commands require development configuration and an exact
  local token. A fabricated bridge grant is rejected.
- No unrelated population zombie is adopted as a managed human body.

The current local body mode is `client_survivor`. Do not re-enable a retired
donor implementation or infer a visible client actor from server telemetry
alone; use the client render diagnostics and direct user observation.
