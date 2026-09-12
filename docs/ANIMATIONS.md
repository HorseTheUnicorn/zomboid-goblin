# Goblin animation coverage

Target: Project Zomboid 42.20.4. The mod supplies conditional animation nodes,
not copies of the game's animation files. Only GoblinNPC actors select them.

| Behavior | Native clips | Control |
| --- | --- | --- |
| Standing with shotgun | Bob_IdleRifle | Idle state |
| Walking / running | Bob_WalkRifle / Bob_RunRifle | Engine simulation owner's pathfinding |
| Aiming / firing | Bob_IdleAimRifle / Bob_AttackRifle | Server cue; aim before damage, client recoil and sound |
| Loot transfer | Bob_IdleLooting_Mid | Server loot job |
| Barricading / construction | Bob_IdleHammering | Server material-backed build job |
| Farm work | Bob_IdleLooting_Low | Native server planting/watering/harvest job |
| Hand crafting / mechanic work | Bob_IdleMaking | Server-native material-backed job |
| Sawing logs | Bob_IdleSawLog | Native SawLogs recipe |
| Low-fence crossing | Bob_VaultOver_Start_Rifle / Bob_VaultOver_End_Rifle | Native crossing state and completion events |
| Window crossing | Bob_ClimbWindowStart / Bob_ClimbWindowEnd / Bob_ClimbWindowObs_End | Native crossing state and completion events |
| Passenger entry / ride / exit | Bob_SatChairIn / Bob_IdleDriving / Bob_SatChairOut | Server passenger phase and native seat binding; no driving logic |

Movement/task nodes cover idle, pathfind, sprintPathfind, walktoward and
walktoward-network. Firearm nodes never invoke vanilla bite/collision events:
damage is server-owned and rechecks the player's five-tile defense radius.

Human-only fallback nodes also cover transient native lunge/attack/alert/turn
states during replication. The normal movement/action nodes have higher priority
than these fallbacks; recovery nodes retain their completion events. Only the
current simulator cancels a hostile native state, and it clears the stale path
cache so following can immediately resume. A dedicated spawn outfit lets clients
recognize the visuals before the identity roster arrives; pending assets retry
every 100 ms and the identified carrier is hidden until its appearance is ready.

The player isRunning flag stays false: the 42.20.4 player fence-vault branch
requires a BodyDamage object that IsoZombie lacks. Native speedType and the
human running clip provide running. The useless flag suppresses idle wandering,
but must be false when entering an explicitly requested walking path.

Work tools are sent in the authoritative companion roster and displayed in
place of the shotgun while working; combat cues temporarily restore the gun.
Farm actions currently share the low-work clip, not separate pouring/scythe clips.
Client display items are stowed before native pathfinding/crossings and while
riding. This avoids 42.20.4's player-only held-item packets when an IsoZombie
climbs a window; inventory and server-owned tools are retained.

This does not implement every player timed action. Vehicle driving, rope/high
wall traversal, workstation crafting, eating/drinking, and player injury
or death transitions need separate implementations and acceptance tests.
Goblin is protected by default. A compatible skeleton enables clips, not those
gameplay systems automatically.

Clip availability and Lua tests are separate from live visual validation.
The new farm/craft/repair and passenger animations/jobs have not yet passed
the local acceptance test.
Deformation, attack timing, crossings and two-client replication must be checked
on the installed game build before declaring a release complete.
