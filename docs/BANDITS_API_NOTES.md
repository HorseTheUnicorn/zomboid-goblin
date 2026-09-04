# Bandits2 API notes

Status: runtime dependency for the GoblinSurvivor NPC body and behavior.
GoblinSurvivor does not copy Bandits2 source; it requires the installed
Workshop package on the .03 server and on joining clients.

The live server is Build 42.20.4. The installed Workshop package is at
steamapps/workshop/content/108600/3268487204/mods/Bandits/42.20 and reports
id=Bandits2 in mod.info. The dependency is the public Workshop item
[B42 Bandits NPC](https://steamcommunity.com/sharedfiles/filedetails/?id=3268487204):

- Workshop item ID: 3268487204
- PZ mod ID: Bandits2
- Role: networked NPC body, profile data, Companion program, and NPC behavior

## Observed B42.20 API surface

These names were read from the installed package on .03; they are not
invented from the Workshop description:

- BanditServer.Spawner.Individual(player, args) accepts a required args.bid,
  optional args.x/y/z, and optional args.program. The wrapper creates one
  networked body and applies the selected Bandits2 profile.
- BanditCustom.Load(), Save(), ClanGet(cid), ClanCreate(cid), GetById(bid),
  and Create(bid) manage the persistent clan/profile data used by the
  adapter.
- BanditBrain.Get(zombie) and Update(zombie, brain) read and publish the live
  Bandits2 brain. Remove(zombie) is available for cleanup.
- BanditUtils.GetCharacterID(character) provides the Bandits2 master ID.
  GetMoveTask(endurance, x, y, z, walkType, dist, closeSlow) and
  GetMoveTaskTarget(endurance, x, y, z, tid, isPlayer, walkType, dist)
  return the framework's verified movement task shapes.
- BanditCompatibility.AddZombiesInOutfit(...) is the body creation
  implementation used by the Bandits2 spawner. GoblinSurvivor calls the public
  spawner rather than this lower-level function.
- Bandit.UpdateTask(zombie, task) and Bandit.ClearTasks(zombie) manage the
  framework task queue.
- The verified friendly program is Companion; the installed package also
  contains ZPCompanion.lua and ZPCompanionGuard.lua.
- The verified speech helper is `Bandit.Say(bandit, phrase, force)`, but it
  accepts a Bandits `SoundTab` phrase key rather than arbitrary text. The
  adapter therefore uses the Bandits2 body method `addLineChatElement` for
  bounded Goblin/Qwen chat text; `ActionExecutor` never calls framework names
  directly.

## Friendly Goblin and managed-roster contract

BanditsAdapter.lua creates or restores one private clan plus one profile per
stable GoblinSurvivor identity. The registry always requires the
`goblin.primary` profile. `GoblinManagedNpcCount` optionally enables the first
bounded entries in the mod's own friendly roster (`npc.sarah`, `npc.bob`,
`npc.dave`, and so on); the default is three managed companions in addition to
Goblin. The registry binds each profile independently and never claims a
normal population zombie.

The adapter reapplies the following state before any body is considered owned:

- clan spawn policy: friendly=true, companion=true, all hostile/group spawn
  modes disabled, and automatic spawn chance set to zero;
- brain policy: hostile=false, hostileP=false, loyal=true, permanent=true,
  and program.name=Companion;
- GoblinSurvivor markers in body mod-data: stable NPC ID, ownership,
  friendly-engine name, role, and protection state. Only `goblin.primary` gets
  the no-damage/immortal safety hooks; managed companions remain ordinary
  survivable friendly bodies.

Squad follow is implemented by GoblinSurvivor high-level code using the
verified `GetMoveTaskTarget` Bandits2 helper: a human-led squad sends Goblin to
the player and the other managed bodies to Goblin; an NPC-led squad sends its
members to the managed leader. Bandits2 still owns the actual networked
movement and Companion behavior.

The adapter is the only runtime module that mentions Bandits2-specific names.
NpcAdapter.lua is a stable facade for the registry, action executor,
telemetry, and Python bridge. There is no vanilla fallback. If the exact API
surface or friendly proof is unavailable, the registry stays in sensor_only
and does not claim an ordinary hostile zombie.

The first combat bridge is intentionally narrow. Python/Lua perception may
nominate only a live non-player zombie within the fixed semantic radius.
GoblinSurvivor restores that one validated engine target while retaining the
Bandits2 friendly brain flags. A generic Bandits2 attack-task contract has not
been assumed; inventory, vehicles, and building actions remain fail-closed
until their exact contracts are verified in the live server.

## Load-order requirement

The dedicated server must advertise and load Bandits2 before GoblinSurvivor:

    WorkshopItems=3268487204,...
    Mods=Bandits2;GoblinSurvivor;...

The order and version must be identical for the server and joining clients.
Steam's server Workshop loadout is the intended client-download path. .76
does not install or run a native Steam/PZ client.
