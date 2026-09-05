# Human runtime checkpoint — 2026-09-04

Local B42.20.4 only. Production and publication gates remain closed.

## Verified

- Custom `HumanSurvivor extends IsoLivingCharacter implements IHumanVisual`
  renders as a separate human beside the player. Neither IsoPlayer nor IsoZombie.
- The B42 FBO renderer traverses `IsoCell.objectList`. Moving-square membership
  alone does not render an actor. `registerVisualObject` registers that object;
  overridden preupdate/update/postupdate avoid the unsafe vanilla NPC simulation.
- `tickVisual` advances the animation/model/light path through `updateForServerGui`.
- Live diagnostics show increasing render calls, an active model, three worn items,
  and `hair=Spike`. Screenshot confirms clothed human body distinct from the player.
- Goblin's profile forces `Spike` after overrides, preserving his fixed hairstyle.
- User movement test: live snapshots moved Goblin out of the house; diagnostics
  transitioned idle -> movement -> idle, and screenshot showed the separate
  clothed human in a walking pose outdoors. Smoothness/collision not proven.
- Storm Lua registration needs an explicit `LuaManager.env` argument and the
  exposed `createGoblinHumanSurvivor` constructor. Register again after Lua resets.

## Current local launch

Use `tools/Start-LocalPzClient.ps1 -Storm` after `tools/dev-install.ps1`.
The launcher disables Storm launcher handoff for the direct disposable test.
Client stdout/stderr: `%USERPROFILE%/Zomboid/Logs/goblin-local-client.*.log`.
Storm internal exceptions: `%USERPROFILE%/Zomboid/Logs/storm/main.log`.

## Unverified / unfinished

- Walking selection from snapshot displacement is verified during the user test.
  Snapshot movement still teleports rather than interpolates.
- Clothes are currently a fixed default outfit, not synchronized equipment.
- Server now runs with `-Storm`. `ServerSurvivorAuthority` owns registered human
  bodies and positions; Lua supplies movement intent and publishes snapshots.
  Live server log confirmed authoritative body creation and client movement.
  Native square collision checks and rejection of cross-floor teleports are
  implemented but not gameplay-validated. Bounded same-floor A* now routes around
  blocked edges (2048 expansions, 500ms replanning); in-game obstacle verification
  is pending. Closed-door interaction and stairs remain unsupported.
  Task decisions and metadata remain in Lua: full Java authority is NOT complete.
- No validated combat, damage/death/recreate, collision/pathfinding, unload/rebind,
  two-client synchronization, jobs, squads, companion behavior, or .76 chat round-trip.
- Legacy Java donor code remains disabled. Never enable it as a fallback.
- No GitHub/Workshop release or production install until the full original gates pass.

## Checks

Java build against installed game succeeded; all 48 Lua files compiled with PZ's
compiler; 72 Python contract tests passed before the latest clothing/motion change.
These source contracts do not prove gameplay. Repeat targeted checks as affected.

`tools/TestGridRoute.java` executes six routing algorithm scenarios against the
built mod jar (detour, checked cardinal edges, budget, sealed start, already
arrived, stopping radius). All passed. This does not validate PZ collision APIs.
