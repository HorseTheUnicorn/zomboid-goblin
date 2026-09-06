# Current work summary

GoblinSurvivor is a standalone Build 42 human-survivor engine. The PZ server
owns the managed roster and authoritative Java bodies. Connected player
clients render local human actors from server snapshots. `.76` owns Qwen,
Python intent validation, durable memory, the atomic bridge, and read-only
tracker telemetry; it does not run a PZ gameplay client.

## Completed in the current checkpoint

- Replaced the retired body approach with `HumanSurvivor`, a real Java human
  actor that is neither a player nor a zombie.
- Added server-side Storm authority for identity, generation, movement,
  ranged combat, firearm state, death, and bounded recreation.
- Added client-side object/model registration, render diagnostics, per-actor
  snapshot retry, generation replacement, and absence cleanup.
- Kept Goblin's hair fixed to `Spike` and equipped the managed roster with
  `Base.AssaultRifle2`.
- Added guarded local hostile-zombie and death/recreation fixtures.
- Updated local Windows launch/cache helpers and synchronized direct and
  Workshop-staging package copies.
- Confirmed local visibility by user observation and client diagnostics.
- Verified the live `.76` agent, relay, and Qwen services. The real Qwen
  adapter uses the shared Goblin personality prompt used by the Discord side
  and produced a valid speech response through the production agent path.
- Published GitHub commit `5b5f640` and completed a guarded `.03` rollout of
  the matching package. The previous server package and save are recoverable
  under the timestamped backup recorded in `LIVE_ENVIRONMENT.md`.

## Latest local evidence

The local Build 42.20.4 run created Goblin plus six companions as
`HumanSurvivor` objects with `isZombie=false`; render calls increased and the
actors were visible. One hostile-zombie fixture was killed with one shot and
no incoming hit. Goblin was recreated at generation 2 after a death fixture.

The latest cold client load took 278 seconds. About 224 seconds were spent
waiting in vanilla world streaming (`WorldStreamer.isBusy()` / `IsoWorld.init`)
with no Workshop items configured; the roster was created after world loading
completed.

## Open work

Melee and combat animation, smooth/collision-aware movement, real job effects,
guard/hauler/farmer/medic/scout behavior, companion and squad behavior,
unload/rebind, reconnect, two distinct clients, and a live in-game
`.76` chat/Qwen round-trip remain open. The repeatable June route failure must
also be resolved or explicitly bounded.

The development branch is pushed through commit `5b5f640`; the normalized
256x256 preview and release metadata are committed. The unlisted Workshop
item is `3797127671` under `HorseTheUnicorn`. Production `.03` is running the
matching direct package; Workshop auto-delivery remains disabled pending a
successful re-test of the unlisted item's server download behavior.
