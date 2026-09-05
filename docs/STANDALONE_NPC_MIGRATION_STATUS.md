# Standalone B42 survivor-engine migration status

Updated: 2026-09-04

## Current checkpoint

The pre-migration work is preserved on the local branch
`checkpoint/pre-standalone-survivor-engine`. The working tree already contains
the bridge, Python controller, tracker, website, persistence, native body
adapter, and local Windows PZ launch scripts. The static contract suite passes
with `python -m unittest discover -s tests -q`.

The authoritative development checkout is:

```text
C:\Users\tomgr\Documents\Codex\2026-09-01\new-chat\work\remote-stage1-tree\zomboid-goblin
```

The visible OneDrive `GoblinSurvivor` folder is an empty Git shell and is not
the active source checkout.

## Verified decisions

- The physical body is an engine-created, networked `IsoZombie` donor. Higher
  layers identify it as a `SurvivorEntity` and never create a fake `IsoPlayer`.
- Donor creation uses the verified Build 42 public factory surface already in
  the adapter (`SurvivorFactory.CreateSurvivor` plus the non-blocking vanilla
  population fallback). The installed B42 multiplayer server exposed the
  documented `createZombie` signature but blocked its server thread, so the
  synchronous factory is skipped on the dedicated server. Direct
  `IsoZombie.new(...)` is intentionally forbidden: it was unsafe in the
  installed runtime.
- Bandits is reference material only. The installed local reference is
  Workshop item `3268487204`, version directory `42.20`; it is not a runtime
  dependency and its namespace is not imported by the mod.
- The server remains authoritative for identity, brain state, tasks, and
  commands. Clients receive normal PZ entity replication plus the bounded
  GoblinSurvivor state channel.
- Goblin uses the same survivor engine as companions. Protection and external
  Qwen control are profile capabilities, not alternate body implementations.

## Migration stages

### Completed before this stage

- Native adapter boundary and friendly-body ownership markers.
- Bridge/telemetry/tracker integration without a native PZ client on `.76`.
- Bounded spawn retry and stale-body removal safeguards.
- Local Windows Build 42 package synchronization and local UDP server scripts.

### This stage

- Establish the standalone namespace and persistent survivor identity markers.
- Add a single authoritative `Survivorize(entity, profile)` conversion path.
- Separate task queues, actions, brain state, perception/cache, visuals,
  survivor update orchestration, and zombie interaction into GoblinSurvivor
  modules, including a bounded survivor combat facade.
- Add deterministic local test-survivor controls and Windows development
  install/log/package tooling.
- Record the installed Bandits behavior as a non-shipping reference.

### Release gates still open

1. Human visuals must be confirmed in local single-player and local MP.
2. Normal zombies must target survivors without losing valid player targets.
3. Survivor melee combat must be implemented and tested.
4. Local one- and two-client synchronization must pass.
5. Body unload/rebind and Goblin protected recovery must pass.
6. Qwen intent integration must be tested only after deterministic fallback is
   stable.
7. Bandits-off package validation must pass before any `.03` deployment.

No production `.03` files or saves are changed by this stage.
