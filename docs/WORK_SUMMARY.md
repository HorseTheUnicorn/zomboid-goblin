# Current work summary

Goblin is designed as a persistent, server-side Project Zomboid NPC. `.03`
owns the networked body and exact world actions; `.76` owns Qwen, the Python
controller/relay, durable memory, and the read-only tracker. `.76` has no
native PZ/Steam gameplay client.

The current source migration replaces the previous external body dependency
with `NativeNpcAdapter.lua`. The adapter uses the documented Build 42 native
`createZombie`/`SurvivorFactory` surface, applies a friendly survivor
descriptor when available, and keeps a bounded `addZombiesInOutfit` fallback.
It marks every body with GoblinSurvivor mod data, binds only marked bodies or
short-lived spawn reservations, owns movement/speech/targeting, and never
claims a normal population zombie.

The Python side has a typed `NpcBodyDriver`, strict intent validation,
deterministic safety/entity/squad/base-job gates, bounded SQLite telemetry,
and the atomic filesystem bridge. The Lua side has bounded spawn/rebind
behavior, protection hooks, separate coarse/exact telemetry, semantic target
resolution, chat forwarding, native movement/combat, and settlement
assignment persistence.

The source changes are currently local and uncommitted in the Windows project.
The local PZ installation has been identified as Build 42.20.4 at
`C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid`. The new
PowerShell harness synchronizes the direct mod package, Workshop staging
package, bridge marker/config, and a separate `goblin-local` server profile
under `C:\Users\tomgr\Zomboid`.

Production `.03` remains untouched during this work. Its existing package,
loadout, save, and service are not being restarted for local development.
The next evidence needed is a local server boot followed by a local player
joining: confirm native bootstrap, Goblin spawn, friendly filtering, native
movement/speech, persistence, and bounded death recovery. Only after those
checks pass should a separately approved production migration be considered.

Automatic client delivery still requires publishing the self-contained
GoblinSurvivor package as a new unlisted Workshop item and then adding that
new ID to a guarded production rollout. Until then, the direct Windows
package is the authoritative test copy.

Local checks cover strict bridge behavior, semantic coordinate separation,
NPC command publication, deterministic squad/job policy, native adapter
contract, and tracker read-only routes. A live local in-world test remains
necessary before the native milestone is complete.
