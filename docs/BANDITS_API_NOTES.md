# Bandits2 API notes

Status: active runtime dependency for the friendly NPC body. GoblinSurvivor
does not copy or publish Bandits2 assets; the server and joining clients use
the published Workshop item.

The live server is Build 42.20.4. Its Workshop cache and active
`WorkshopItems=` configuration were inspected through the Proxmox console.
The initial inventory found no Bandits framework files. The public Workshop
item was then downloaded anonymously with SteamCMD as the `zomboid` user and
enabled in the live `servertest` profile for compatibility inspection. The
installed package is at
`steamapps/workshop/content/108600/3268487204/mods/Bandits/42.20` and reports
`id=Bandits2` in `mod.info`.

The candidate dependency identified for the server is the official Workshop
item [B42 Bandits NPC](https://steamcommunity.com/sharedfiles/filedetails/?id=3268487204):

- Workshop item ID: `3268487204`
- Published mod ID reported by the Workshop page: `Bandits2`
- Intended role: NPC framework and Bandits behavior, not a Goblin-specific mod

The package's public spawner is used only through `BanditsAdapter.lua`. The
adapter creates or repairs one stable Goblin clan/profile, disables that
profile's random spawning, and passes explicit `hostile=false`,
`hostileP=false`, `loyal=true`, and `permanent=true` values. It rechecks those
fields after creation and on every tick. A normal vanilla zombie is never
accepted as a friendly replacement.

## Observed B42.20 API surface

The following names were read from the deployed Lua package on `.03`; they are
not inferred from the Workshop description:

- `BanditServer.Spawner.Type(player, args)` spawns a group using a required
  `args.cid`, with optional `args.size`, `args.program`, `args.x/y/z`, or
  `args.spawnPoints`.
- `BanditServer.Spawner.Clan(player, args)` spawns a clan using `args.cid` and
  the same group-oriented arguments.
- `BanditServer.Spawner.Individual(player, args)` spawns one individual using
  `args.bid`, optional `args.x/y/z`, and optional `args.program`.
- `BanditServer.Spawner.Restore(player, args)` calls the package's restore path
  using a serialized brain argument.
- `BanditServer.Spawner.Vehicle(player, args)` is the package's vehicle spawn
  entry point.
- `BanditServer.Wanderers.AddGroup(group)` registers a wandering group;
  `BanditServer.Wanderers.destinations`, `.speed`, and `.contactRange` are
  package-owned scheduler state.
- `BanditBrain.Get(zombie)`, `BanditBrain.Add(zombie, brain)`,
  `BanditBrain.Remove(zombie)`, `BanditBrain.HasTask(brain)`,
  `BanditBrain.HasMoveTask(brain)`, `BanditBrain.HasActionTask(brain)`,
  `BanditBrain.HasTaskType(brain, taskType)`, and
  `BanditBrain.HasTaskTypes(brain, taskTypes)` are exposed by the deployed
  shared brain module.
- `BanditUtils.IsController(zombie)`, `GetZombieID(character)`,
  `GetCharacterID(character)`, `GetClosestBanditLocation(character, config)`,
  `GetTarget(character, config)`, and `GetMoveTaskTarget(...)` are present in
  the deployed utility module.
- `BanditCustom.GetMods()`, `Load()`, `Save()`, `ClanCreate(cid)`,
  `ClanDelete(cid)`, `ClanGet(cid)`, `ClanGetAll()`, `Create(bid)`,
  `Delete(bid)`, `Get(bid)`, and `GetAll()` are present in the deployed custom
  data module.

`BanditsAdapter.lua` is the sole runtime boundary around the validated
`Individual`, `Custom.Create/GetById`, `Brain.Get/Update`, and brain-task
fields. `NpcAdapter.lua` keeps the rest of GoblinSurvivor independent of
Bandits-specific names. The adapter logs one bounded spawn diagnostic and
never retries an unbound request in a per-tick loop.

## Remaining inspection before extending control

Before enabling NPC control, record the exact deployed files and functions for:

- NPC creation and lookup;
- brain/task representation;
- movement/follow/attack tasks;
- friendly/hostile state;
- survivor persistence and entity recreation;
- inventory/equipment and animation state;
- target handling, death/despawn, and multiplayer synchronization;
- public extension hooks.

`BanditsAdapter.lua` is the only module allowed to depend on Bandits-specific
names; `VanillaNpcAdapter.lua` is retained only as a non-friendly compatibility
fallback. If a capability is absent, the selected adapter returns an explicit
unsupported result and the deterministic safety layer stays in
`sensor_only`. It must never claim that an NPC action succeeded merely because
a command was accepted by the bridge.
