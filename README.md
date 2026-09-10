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

- Dedicated PZ server: owns all Goblin bodies and all gameplay mutations.
- Local Qwen/Python service: interprets addressed chat and generates in-character speech.
- `GoblinSpawner.lua`: one `addZombiesInOutfit(... total=1 ...)` spawn path only; no `createRealZombieAlways`, `createRealZombieNow`, or manual body insertion fallbacks.
- `GoblinBody.lua`: friendly/humanized invariants and supplied-model clothing registration.
- `GoblinMovement.lua`: native `PathFindBehavior2`; no coordinate stepping or teleport movement.
- `GoblinLoot.lua`: transfers real existing items and delivers cargo to the owner's base.
- `GoblinClient.lua`: recognizes every replicated Goblin by its own online/NPC identity and keeps the custom model/human animation variables applied without forcing animation frames or `ZombieIdleState`.

When a player disconnects, their live Goblin is removed but their persistent identity, base, and task record remain. When they return, their own Goblin is recreated/recovered. Ordinary zombies are never claimed as Goblins.

## Character asset

The supplied source character is preserved under `art/goblin`, and the game package uses:

```text
common/media/models_X/Goblin_PZ_MysteryRig.fbx
common/media/textures/Goblin_PZ_MysteryRig/Material_1_basecolor.png
common/media/clothing/clothingItems/Goblin_MysteryBody.xml
```

The clothing XML references `Goblin_PZ_MysteryRig` **without** an `.fbx` suffix and resolves its texture relative to `media/textures`.

## Configuration

The important defaults remain in `goblin-bridge/config.ini` / `ops/server-options.example`:

```ini
GoblinEnabled=true
GoblinNpcId=goblin.primary
GoblinNpcVisualAsset=Goblin_PZ_MysteryRig
GoblinWeapon=Base.Machete
GoblinNpcProtected=true
GoblinFollowDistance=3
GoblinFollowWalkDistance=4
GoblinFollowRunDistance=9
GoblinSpawnOffset=4
```

`GoblinNpcId` is a prefix. Runtime identities are generated as `goblin.primary.<player>`.

## Development

```text
python -m compileall -q goblin_zomboid tests
python -m unittest discover -s tests -v
```

The repository also contains a GitHub Actions workflow that runs these checks on pushes and pull requests.
