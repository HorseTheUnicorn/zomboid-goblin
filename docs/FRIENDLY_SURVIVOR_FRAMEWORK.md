# Friendly survivor framework

The initial native controller lives in:

```text
mod/Contents/mods/GoblinSurvivor/42/media/lua/server/GoblinSurvivor/FriendlySurvivor.lua
```

It creates a normal multiplayer `IsoZombie` through Build 42's public
`createZombie(x, y, z, SurvivorDesc, outfit, direction)` factory. The Lua
layer intentionally does not call an `IsoZombie` Java constructor: the factory
is responsible for registering the body in the world and in the multiplayer
simulation.

## Responsibilities

`FriendlySurvivor.lua` owns four small responsibilities:

1. mark the body with stable mod data (`goblin_friendly_survivor`, body class,
   target class, and ownership);
2. clear zombie target, aggro, eating, thumping, and attack-square state;
3. scan the bounded `getOnlinePlayers()` collection on every server tick,
   choose the nearest live player within 30 tiles, and request a path toward
   that player; and
4. publish a compact state snapshot without moving the body on the client.

The controller uses `pathToLocationF` first and `pathToLocation` as a fallback.
It never assigns the player to `IsoZombie:setTarget`, because that target is a
combat target and would re-enable zombie attack behavior. The player object is
used only as a read-only source of position and username.

## Behavior stripping boundary

The current public Build 42 Lua surface exposes reliable target/aggro/eating/
thump controls, so those are cleared both when the body is created and on each
update. Optional setters such as `setBite`, `setCantBite`,
`setVoiceSoundName`, and `setBiteSoundName` are capability-gated; the code does
not assume they exist. The controller also clears the public sound-attraction
fields when the Java proxy permits those field writes.

Build 42 does not expose a public per-instance setter for every zombie audio
callback or a general Lua override for the Java `cantBite()` implementation.
Therefore the framework suppresses the causes of those transitions and
reasserts that policy, but it does not claim a complete Java audio override.
A future explicit engine hook can be added inside this module without
changing the registry or network contract.

## Multiplayer synchronization

The server is authoritative:

* PZ's native world-entity stream replicates the `IsoZombie` position and
  movement to connected clients.
* `FriendlySurvivorNetwork.lua` broadcasts the mod-owned identity, mode,
  target username, distance, and sequence through standard
  `sendServerCommand` packets at most twice per second.
* `FriendlySurvivorClient.lua` receives the packet with `OnServerCommand` and
  keeps a read-only UI cache. It never applies a position or accepts a client
  movement claim.
* A client may request the latest snapshot through `sendClientCommand`; the
  server replies only with the last read-only state.

## Tick budget

The controller is invoked from the server `OnTick` path. The nearest-player
calculation is O(number of connected players) for the one managed body; it is
not a world or zombie-list scan. Path requests are limited to once every 250
ms, and custom state packets are limited to once every 500 ms. No network or
LLM operation runs in the tick callback.
