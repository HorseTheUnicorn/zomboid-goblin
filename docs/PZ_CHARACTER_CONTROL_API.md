# Project Zomboid character-control API

This document records the Build 42 APIs currently used by the GoblinSurvivor
Storm bridge. It is an implementation boundary, not a list of functions that
Qwen may call.

## Authority boundary

The `.76` process receives bounded semantic state and emits a validated plan
using logical ids such as `goblin.primary`, `player.alice`, and `npc.0001`.
It never receives a PZ object, cell, coordinate, route, Lua expression, or
Java method name. The dedicated server remains the only component allowed to
resolve a logical target and mutate the world.

The server path is:

```text
Qwen plan (.76)
  -> Python schema/reference/safety validation
  -> atomic command bridge
  -> Storm RemoteCommandConsumer
  -> Lua wire validation and logical-target resolution
  -> ServerSurvivorAuthority
  -> HumanSurvivor / PZ world
```

## Native human body

`HumanSurvivor` is the current native human body implementation. It extends
`IsoLivingCharacter` and implements the small `IHumanVisual` contract used by
the client renderer. It is not an `IsoPlayer`, `IsoZombie`, or a disguised
zombie.

The constructor exposed to Lua is:

```java
HumanSurvivor(SurvivorDesc descriptor, IsoCell cell, int x, int y, int z)
```

The server authority uses these bounded operations:

- `setMovingSquare(IsoGridSquare)` and the native position/direction fields to
  keep the body on the PZ grid;
- native `IsoGridSquare`/cell lookup and `IsoGameCharacter` movement state for
  deterministic navigation;
- `ensureFirearm()`, `fireAt(IsoZombie)`, `ensureMeleeWeapon()`, and
  `meleeAt(IsoZombie)` for bounded hostile-zombie combat;
- `setFirearmPose(...)`, `setMeleeAttackPose(...)`,
  `setMovementMode(...)`, and `setTraversalPose(...)` for presentation state;
- `applyOutfit(...)`, `forceGoblinAppearance()`, and the human visual/model
  registration methods for deterministic appearance;
- `receiveZombieDamage(...)`, `restoreHealth(...)`, and
  `markSurvivorDead(...)` for the server-owned lifecycle;
- `getBodyDamage()` as the compatibility object required by the Build 42
  fence traversal state;
- `ensureVisualModel()`, `ensureVisualRegistration()`,
  `registerVisualObject()`, `unregisterVisualObject()`, and
  `visualModelManaged()` for the client-side model path.

The client shim additionally uses the supported model manager registration,
moving-square updates, render flags, and interpolated snapshots so a real
human model is visible to each multiplayer client without adding the body to
the vanilla zombie list.

## Storm-exposed bridge functions

When the dedicated server loads the Storm mod, it exposes only these Lua
bridge functions:

```text
createGoblinHumanSurvivor(descriptor, cell, x, y, z)
stepGoblinServerActor(state, target, stopDistance)
persistGoblinActorCargo(state)
markGoblinHumanDead(actorId, reason)              # local test gate only
spawnGoblinCombatFixture(actorId)                 # local test gate only
spawnGoblinCombatObservation(actorId)             # local test gate only
buildGoblinAgentPerception(state)
goblinAgentCapabilities()
validateGoblinSurvivorCommand(message)
goblinSurvivorCommandRejectReason(message)
normalizeGoblinAction(action)
```

The debug spawn/death functions are guarded by the disposable local-test
configuration and are not gameplay capabilities. `stepGoblinServerActor` is
the only movement entry point; it consumes server-owned state and a
server-resolved target table. No external process can call a native PZ method
through the bridge.

## Speech path

`ServerSurvivorAuthority` handles a validated `SAY` action by broadcasting a
versioned speech packet. The client shim renders the same message as overhead
speech and, when `zombie.chat.ChatManager` is available, inserts it into the
vanilla general chat channel with Goblin's author name. Incoming addressed
player chat is captured by the client relay, revalidated by the server, and
written as an event for the `.76` service. The service may answer with a
bounded plan containing Goblin speech and up to four high-level survivor
commands.

## Capability policy

The capability list is intentionally smaller than the internal compatibility
action set. `.03` publishes only actions that the current client-survivor
executor implements: `NOOP`, `SAY`, `FOLLOW_PLAYER`, `FOLLOW_GOBLIN`, `HOLD`,
`REGROUP`, `RETURN_HOME`, `DEFEND_PLAYER`, `RETREAT`, `LOOT_AREA`,
`SCAVENGE_AREA`, `FORM_SQUAD`, `DISMISS_SQUAD`, `ASSIGN_JOB`, and `SECURE_BASE`.
Unknown actions, stale commands, malformed targets, unsafe fields, and any
attempt to assign Goblin away from his permanent leader role fail closed.
