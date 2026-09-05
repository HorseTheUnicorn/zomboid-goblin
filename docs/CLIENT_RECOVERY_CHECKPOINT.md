# Client recovery checkpoint — 2026-09-05

## Snapshot retry fix

The client used to consume a snapshot sequence before creating its visual
body. A failed constructor therefore prevented retrying the same snapshot,
and the tick retry path considered only the last roster member.

`ClientSurvivorActor.lua` now:

- commits a sequence only after the relevant actor is created successfully;
- retries every pending roster member at a bounded interval;
- rejects stale packets while retaining a newer pending snapshot;
- cancels retries for actors absent from the newest roster; and
- unregisters the old visual before a generation replacement.

`tools/TestClientActorRetry.java` executes the actual client Lua module in the
installed game's Kahlua VM with mocked world and constructor services. It
covers bounded failures, all-roster retry, recovery without another packet,
stale packet rejection, duplicate prevention, generation replacement, and
absence cleanup. The test passes.

## Live verification

The current client log confirms seven Java human actors were created and
rendered. Diagnostics include `inObjectList=true`,
`pendingRemoval=false`, an active model, increasing render calls,
`hair=Spike`, and `firearm=Base.AssaultRifle2`. The user confirmed the
characters are visible in the game. This closes the visual-spawn gate for
the single-client local run.

The local client needed 162 seconds for its cold Build 42 world load. The
watchdog's stack was waiting in vanilla `IsoWorld.init` during
`WorldStreamer.isBusy()`, not inside the Goblin actor constructor. The local
profile has no Workshop items, so there was no Workshop download in this
run.

## Parallel-client probe

`tools/Stage-LocalPzClientCache.ps1` stages an isolated PZ data root and
`tools/Start-LocalPzClient.ps1 -AllowMultiple -CacheDir ...` launches a
parallel non-Steam client without reusing the primary cache. The probe
reached the server but was rejected because it reused the first client's
username. The helper does not invent a second identity; repeat the test with
a distinct username entered through the native PZ login flow. Do not count
this as a two-client pass.

## Remaining lifecycle work

Live tests still needed: reconnect, server restart, cell unload/rebind,
duplicate-body cleanup, two distinct clients, jobs, squads/companions,
melee, combat animation, and `.76` chat/Qwen round-trip. Do not deploy to
`.03` or publish the Workshop item from this checkpoint.
