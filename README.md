# Zomboid Goblin

Goblin is a friendly Project Zomboid Build 42 companion system with **one Goblin per connected player**. Each companion is a normal networked `IsoZombie` managed by the dedicated server, identified independently as `goblin.primary.<player>`, rendered with the supplied Mystery Rig model, and kept out of the vanilla zombie bite/lunge AI.

The design deliberately follows the small, proven pattern used by working NPC-style zombie conversions: spawn a normal engine body, mark it, keep friendly/human movement invariants asserted, and let Project Zomboid own pathfinding and animation. The project does **not** depend on Bandits2 at runtime and does not copy Bandits2 source.

## What Goblin does

Each online player gets exactly one companion. A Goblin follows its owner by default, can hold position, fight nearby ordinary zombies, collect real existing loot from the ground and nearby containers, carry it back to that player's saved base, and deposit it into a nearby base container (or onto the base square if no container is available).

A player's base defaults to their position when their persistent Goblin record is first created. It can be changed in game with `/goblin base`, or naturally through Qwen with phrases such as `Goblin, this is our base. Remember it.`

Useful in-game commands are:

```text
/goblin spawn
/goblin follow
/goblin wait
/goblin loot [food|medical|tools|ammo|surprise]
/goblin base
/goblin home
/goblin attack
/goblin equip
/goblin state
```

Ordinary chat also works when the player addresses Goblin by name, for example:

```text
Goblin, follow me.
Goblin, stay here.
Goblin, loot this place and bring it home.
Goblin, this is our base. Remember it.
Goblin, help me with these zombies.
Goblin, what do you think of this dump?
```

## Qwen personality

The local Qwen model is the semantic brain and conversational voice, not the movement engine. It is taught that there is one Goblin per player and receives the exact `controlled_npc_id` and `controlled_owner` for the player who spoke.

Goblin's persona is feral, friendly, loyal, dry, argumentative, and theatrically inspired by Vladimir Lenin. He calls the player "comrade," turns mundane survival into absurd revolutionary rhetoric, uses occasional recognizable Lenin references, and prefers original Lenin-flavored jokes over falsely attributing invented lines as real quotes. This is fictional Project Zomboid roleplay; the prompt explicitly avoids advocacy of real-world political violence.

Qwen emits only high-level intents. Lua resolves movement, targets, loot, base delivery, combat, spawning, and persistence deterministically on the dedicated server.

## Runtime architecture

- Dedicated PZ server: owns Goblin identities, tasks, destinations and gameplay mutations. Native zombie motion runs on the simulation owner assigned by the engine.
- Local Qwen/Python service: interprets addressed chat and generates in-character speech.
- `GoblinSpawner.lua`: one `addZombiesInOutfit(... total=1 ...)` spawn path only; no `createRealZombieAlways`, `createRealZombieNow`, or manual body insertion fallbacks.
- `GoblinBody.lua`: friendly/humanized invariants and supplied-model clothing registration.
- `GoblinMovement.lua` / `GoblinLocomotion.lua`: native path commands on the simulation owner, with live follow targets, a three-tile stopping radius, and blocked-path retries.
- `GoblinLoot.lua`: transfers real existing items and delivers cargo to the owner's base.
- `GoblinClient.lua`: recognizes every replicated Goblin by its own online/NPC identity and keeps the custom model/human animation variables applied without forcing animation frames or `ZombieIdleState`.

When a player disconnects, their loaded Goblin parks in place. Its identity, base, task and last position are checkpointed in world `ModData`. Reconnecting recovers the same loaded actor and inventory. If the engine has unloaded the actor or a restart requires recreation, the saved identity/task/position are restored; a following Goblin may rejoin near its owner if that square is unavailable. A waiting Goblin waits for its saved square to load. Inventory preservation across engine unload/recreation is not yet guaranteed. Ordinary zombies are never claimed as Goblins.

## Character asset

The supplied source character is preserved under `art/goblin`, and the game package uses:

```text
common/media/models_X/Skinned/Goblin/Goblin.fbx
common/media/textures/Goblin/Goblin.png
common/media/clothing/clothingItems/Goblin_MysteryBody.xml
```

The clothing XML references `Skinned/Goblin/Goblin` without an `.fbx` suffix and `Goblin/Goblin` relative to `media/textures`. `GoblinAppearance.lua` resolves the registered script item into the zombie's actual `ItemVisuals`, retries asynchronous loading, and repairs visuals replaced during replication. The four vanilla uniform items remain equipped alongside the costume. No global human-model override or `OutfitManager.instance` Lua access is used.

## Configuration

The important defaults remain in `goblin-bridge/config.ini` / `ops/server-options.example`:

```ini
GoblinEnabled=true
GoblinNpcId=goblin.primary
GoblinNpcVisualAsset=Goblin_PZ_MysteryRig
GoblinWeapon=Base.Pistol3
GoblinNpcProtected=true
GoblinFollowDistance=3
GoblinFollowWalkDistance=4
GoblinFollowRunDistance=9
GoblinSpawnOffset=4
```

`GoblinNpcId` is a prefix. Runtime identities are generated as `goblin.primary.<player>`.

## Development

```text
python -m pip install -r requirements-dev.txt
python -m compileall -q goblin_zomboid tests
python -m unittest discover -s tests -v
```

The repository also contains a GitHub Actions workflow that runs these checks on pushes and pull requests. Lua behavior tests execute production modules in Lua 5.1 with engine boundary doubles; a live B42 server/client check is still needed for actual rendering and navigation.
