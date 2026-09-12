# Zomboid Goblin

Goblin is a friendly Project Zomboid Build 42 companion system with **one Goblin per player**. Each companion uses a networked `IsoZombie` as its multiplayer carrier, with a native human body, a Community Rig-derived green skin, the supplied Goblin head, and human animations. The dedicated server owns companion tasks and prevents the carrier's vanilla bite/lunge behavior.

The game owns pathfinding and animation. A **server-only Storm helper** supplies atomic bridge files, native inventory snapshots, NPC-safe crafting/repair adapters, and passenger-seat protection. Clients use the ordinary game executable with this mod's Lua/assets; neither Storm nor a client Java shim is required.

## What Goblin does

Each online player gets exactly one companion. A Goblin follows its owner, can hold position, fight nearby ordinary zombies and collect real existing loot. Deliveries go on the ground at the owner's current feet by default. If the player sets a base, deliveries instead use a container on that base square, or the ground there when no suitable container is available.

New companions have no base until their player sets one with `/goblin base`, or through Qwen: `Goblin, this is our base. Remember it.` Use `/goblin base clear` to restore feet-first delivery. Existing saved bases are preserved on upgrade because older records do not distinguish manually set bases from automatic spawn-point bases. Clear an old unwanted base explicitly.

Useful in-game commands are:

```text
/goblin spawn
/goblin follow
/goblin wait
/goblin enter
/goblin exit
/goblin open door
/goblin close curtains
/goblin open window
/goblin loot [food|medical|tools|ammo|surprise]
/goblin base
/goblin home
/goblin attack
/goblin fortify
/goblin build crate
/goblin farm plow
/goblin farm sow Cabbages
/goblin farm water
/goblin farm harvest
/goblin farm tend
/goblin craft SawLogs 2
/goblin repair engine
/goblin repair bodywork
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
Goblin, open the door.
Goblin, close the curtains.
Goblin, sow cabbage seeds.
Goblin, craft 2 SawLogs.
Goblin, repair the car.
Goblin, what do you think of this dump?
```

Direct orders run on the server without waiting for Qwen, including refusals such as a locked door. Qwen cannot replace a rejected direct order with an unrelated task. Accepted means **queued**, not already completed.

Explicit kill orders use the same aim/fire controller as automatic defense. Goblin approaches a blocked or distant target for a clear shot, gives up with a reason after 45 seconds without reaching one, and never acknowledges a queued order as an already-fired pistol. Damage logging records native target health before/after; a no-damage hit is reported as a failure.

### Work jobs and supplies

Goblin retains a reusable native tool kit. Tools are repaired/replaced as needed and are excluded from loot deliveries; the kit does not create fuel, seeds, water, planks, nails, recipe ingredients, or repair materials. The companion has a bounded 100-weight carrying allowance for tools and cargo. Additional installed recipe tools may be supplied only for native reusable tool inputs, including multiple copies when the installed recipe requires them (up to 32 per input). This does not implement otherwise unsupported jobs.

- Doors/windows: open the nearest unlocked, unbarricaded edge within three tiles of the speaker, after approaching it.
- Curtains: stand inside the house and say “close the curtains”, “shut the blinds”, or `/goblin close curtains`. The order captures that exact building and visits its open native window curtains/sheets across rooms and floors. Goblin approaches and verifies each close; closed curtains are never reopened. He opens accessible route doors, restores interior doors he opened, and closes exterior doors behind him when the doorway is clear. Blocked or unloaded targets are reported, with a 45-second approach limit per curtain and the normal five-minute job limit. Reissue a pending curtain order after a server reload. Door-integrated curtains are not included.
- Farming: `plow` marks **one empty dirt tile under the owner**. Sow/water/harvest/tend work within eight tiles of the set base, or the owner's position when ordered. Sowing consumes the named crop's seed; watering consumes actual water up to the crop's requirement. Tend currently waters and harvests; fertilizing, disease treatment, and weeding are not included.
- Crafting: select an installed Build 42 hand-crafting recipe by script/display name, or `planks`, `rope`, `sheet rope`. Counts are **recipe batches**, 1–10; SawLogs produces the game's native number of planks per log. Inputs are gathered nearby, then native recipe code consumes them and creates outputs. Ordinary nearby work surfaces are checked by native crafting logic. Workstation-only, building, and arbitrary mod callbacks requiring an IsoPlayer are not guaranteed compatible.
- Repairs: marks the nearest parked, unoccupied vehicle within five tiles. `engine` consumes engine spare parts with native skill-based condition gain; `bodywork` uses installed fixing recipes and their supplies/chance of failure. `all` does both. Missing parts require replacement; replacement/install/uninstall is not included.

Farming/crafting/repair jobs report progress or missing supplies, recheck targets before mutations, and stop after five minutes if unfinished. Construction returns to following after 90 seconds without the required materials, explaining what is missing. `/goblin follow` or `/goblin wait` cancels a job. Explicit jobs continue while the owner is idle/offline **if their area remains loaded**. Harvests/crafted cargo use the usual feet/base delivery. Native API errors stop the job to avoid repeating a partial operation.

### Vehicle passengers

While following, Goblin approaches and boards a free passenger seat when the owner's vehicle stops, then gets out when the owner does. `Goblin, get in the car` also selects the owner's vehicle or a nearby one; `Goblin, get out` prevents immediate automatic reboarding until the owner leaves. WAIT can keep him aboard. Boarding requires a free installed seat, an accessible unlocked entrance, and the server seat-protection helper. Exiting waits for a stopped vehicle and a clear exit. Driving is not implemented. Vehicle bindings are session-local; after a world reload companions restore on foot, not into a potentially reused vehicle ID.

New jobs still need native in-game acceptance checks; unit tests and earlier movement/appearance tests alone do not validate navigation through a particular house.

Ready, server-confirmed companions are excluded from the client's one-shot zombie surprise sting. Ordinary zombies remain eligible, and this does not globally mute sound or the separate adaptive threat music.

## Qwen personality

The local Qwen model is the semantic brain and conversational voice, not the movement engine. It is taught that there is one Goblin per player and receives the exact `controlled_npc_id` and `controlled_owner` for the player who spoke.

Goblin's persona is feral, filthy-mouthed, loyal, dry, argumentative, and theatrically inspired by Vladimir Lenin: ruthless toward fictional zombies and protective of his player. Profanity is allowed naturally, without a caricature accent or stereotypes about Russians. A compact offline reference set in `goblin_zomboid/lenin.py` paraphrases themes from the [Marxists Internet Archive Lenin quotations index](https://www.marxists.org/archive/lenin/quotes.htm), choosing a random theme for each ambient generation. Example Goblin lines are original fiction, not historical quotations. There is no website fetch or additional model call during gameplay. This is fictional Project Zomboid roleplay; the prompt explicitly avoids advocacy of real-world political violence.

Addressed conversation remains available alongside direct orders. During eligible downtime after the owner has been still for 30 seconds, each Goblin may offer a short spontaneous Lenin-themed remark on a randomized two-to-four-minute timer. Background generation never blocks the chat queue, is bounded to four seconds, and cannot issue an action. Remarks are suppressed during combat, explicit jobs, vehicle travel, logout, and for 45 seconds after addressed chat; stale replies are discarded.

Qwen emits only high-level intents. Lua resolves movement, targets, loot, base delivery, combat, spawning, and persistence deterministically on the dedicated server.

## Runtime architecture

- Dedicated PZ server: owns Goblin identities, tasks, destinations and gameplay mutations. Native zombie motion runs on the simulation owner assigned by the engine.
- Local Qwen/Python service: interprets addressed chat and generates in-character speech.
- `GoblinSpawner.lua`: one `addZombiesInOutfit(... total=1 ...)` spawn path only; no `createRealZombieAlways`, `createRealZombieNow`, or manual body insertion fallbacks.
- `GoblinBody.lua`: friendly/humanized invariants and supplied-model clothing registration.
- `GoblinMovement.lua` / `GoblinLocomotion.lua`: native path commands on the simulation owner, with live follow targets, three-tile bodyguard spacing, immediate running when the owner runs/sprints, and blocked-path retries. Following Goblins back away from the chair's adjacent-tile threat ring when too close; player threat checks and ordinary zombies are unchanged. Rest still needs a clear nearby area, including when Goblin is performing a separate job.
- `GoblinLoot.lua`: transfers real existing items and delivers cargo to the owner's feet or set base.
- `GoblinClient.lua`: recognizes every replicated Goblin by its own online/NPC identity and keeps the custom model/human animation variables applied without forcing animation frames or `ZombieIdleState`.

Activity priority is explicit orders first, then following a moving owner. After **30 seconds without owner movement**, Goblin may scavenge nearby or fortify the set base when real materials are available. Moving again or reconnecting cancels only autonomous jobs before the next work/loot mutation. Carried loot is retained and delivered when he catches up, or on the next idle base-delivery run. Automatic defense can interrupt independent chores, but only targets zombies on the player's floor within **5 tiles of the player**, rechecking that leash continuously. Explicit WAIT, LOOT and BUILD orders remain in effect; explicit ATTACK may pursue beyond the radius. Work only occurs in loaded map areas. With no base and an offline owner, cargo is kept until the owner returns.

After logout, a loaded Goblin can continue chores. Qwen receives the persistent roster and can choose an offline job at the planning interval (60 seconds by default), using a one-use server grant tied to that Goblin and task sequence. Reconnects and later explicit orders invalidate delayed offline decisions. Unloaded cells or a paused empty server do not simulate work: no supplies or completed construction are fabricated.

An empty idle loot scan now explores new loaded locations within 24 tiles of the owner or a fixed offline/base anchor, rather than repeatedly searching the same square. Routes time out and rotate if blocked. An offline Goblin with cargo and nowhere to deliver patrols while retaining it. Only adjacent, unlocked, unbarricaded doors/windows on the route are opened through native server APIs; locks are not bypassed.

The world map and minimap display your own Goblin's name and position. Gray markers are last-known positions, not simulated off-screen movement. After a player death and respawn, the same companion runs back when nearby or is relocated to a free loaded square near the new character when more than 30 tiles away/on another floor. The native simulator applies relocation once; identity and carried inventory are retained. Ordinary reconnects still preserve explicit WAIT orders.

Identity, feral name, base, task and last position are checkpointed in world `ModData`. Reconnecting recovers the same loaded actor. The server helper saves native inventory data every two seconds when it changes and on world saves, including nested item data. Recreation restores that snapshot before equipment setup. Snapshots are versioned, checksummed and atomically replaced; invalid snapshots fail closed instead of being overwritten with an empty inventory. World changes and inventory files are not a single crash-atomic transaction, so abrupt termination can lose the most recent changes. A following Goblin may rejoin near its owner if its saved square is unavailable; a waiting Goblin waits for the saved square to load. Ordinary zombies are never claimed as Goblins.

## Character asset

The supplied source character is preserved under `art/goblin`, and the game package uses:

```text
common/media/models_X/Skinned/Goblin/GoblinHead.x
common/media/textures/Goblin/Goblin.png
common/media/textures/Body/Goblin/GoblinNativeSkin.png
common/media/clothing/clothingItems/Goblin_MysteryBody.xml
```

The game keeps its stock male body and skeleton. The custom head is weighted only to the native `Bip01_Head` bind matrix. Its clothing XML references `x:Skinned/Goblin/GoblinHead`, and `fileGuidTable.xml` registers the stable clothing GUID. Five visuals are applied: the head plus the native priest shirt, black trousers, black boots and beret. The native face and unused dress surface are masked; there is no full-body mesh override.

The head retains its original matching atlas with `m_MasksFolder=none`. The green body skin is surface-baked from Paddlefruit's Community Rig v4.0.1 onto the installed 42.20.4 body's UVs, including the differing hand UVs, and preserves the native texture's transparent cut-outs. `tools/build_goblin_community.py` builds the assets and `art/goblin/Goblin_Community_Final.blend`; the accompanying report records hashes and geometry checks. See [the authoring notes](art/goblin/WORKSHOP.md) for source attribution and rebuilding. A Blender preview does not replace an in-game render test.

Human idle, walk, run, aim, firearm recoil, looting, hammering, farm work, hand crafting, sawing, mechanic work and low-fence/window crossing are explicitly mapped. Vehicle driving and other unimplemented player-only systems are not made functional merely by sharing the skeleton. See [animation coverage](docs/ANIMATIONS.md).

Goblin's native zombie vocal loop and bite/hurt variants use private, zero-volume sound aliases. Ordinary zombies, footsteps, tools and weapon sounds are not muted; Qwen still replies through in-game text chat.

Your loaded Goblin stays opaque when you turn away, and his nearby overhead name remains visible outside your viewing cone. This is owner-only client presentation: ordinary zombies and other players' companions retain native fading. Other floors and unloaded bodies are not revealed, and initial spawning remains hidden until the skin is ready. Walls can still occlude the model; the map marker remains the distant/last-known fallback.

## Configuration

The important defaults remain in `goblin-bridge/config.ini` / `ops/server-options.example`:

```ini
GoblinEnabled=true
GoblinNpcId=goblin.primary
GoblinNpcVisualAsset=Goblin_Community_Human
GoblinWeapon=Base.DoubleBarrelShotgun
GoblinNpcProtected=true
GoblinFollowDistance=1
GoblinFollowWalkDistance=2
GoblinFollowRunDistance=9
GoblinSpawnOffset=4
```

`GoblinNpcId` is a prefix. Runtime identities are generated as `goblin.primary.<player>`.

Qwen on `.76` serves one resident Qwen3-8B Q4_K_M model through both `goblin-fast` and `goblin-smart` aliases. Normal chat generates speech and a validated action in one inference call. The Python service and Lua package must both use protocol **2**. Run `python -m goblin_zomboid.daemon`, not the heartbeat-only agent entry point. The service defaults to disabled/paused; enable it deliberately after verifying its bridge root and Qwen endpoint. See [deployment](docs/DEPLOYMENT.md) for server-only Storm and the local SSH tunnel setup.

Chat polling is separate from the five-second telemetry heartbeat: incoming messages are checked every 250 ms, and queued players do not wait another heartbeat between replies. Generated chat is schema-constrained and still passes the strict action validator. Failures generate a short radio-error message and per-chat diagnostics; they do not execute a guessed action. Clear native commands such as `Goblin, secure the base` work immediately even if Qwen is unavailable.

## Development

```text
python -m pip install -r requirements-dev.txt
python -m compileall -q goblin_zomboid tests
python -m unittest discover -s tests -v
```

The repository also contains a GitHub Actions workflow that runs these checks on pushes and pull requests. Lua behavior tests execute production modules in Lua 5.1 with engine boundary doubles; a live B42 server/client check is still needed for actual rendering and navigation.
