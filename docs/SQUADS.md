# Squads and formations

Squads have a stable id, leader, bounded member list, and one of `line`,
`wedge`, `column`, `ring`, or `loose` formations. Selection excludes dead,
inactive, incapacitated, and critical workers and never drops the configured
base-guard floor. Formation offsets are semantic; Lua resolves them against
the live server state.

The model may request a squad after an authorized commander has asked for the
change in game. It cannot teleport, specify offsets as world coordinates, or
directly manipulate an NPC brain. The server-minted grant is one-use and
expires quickly, so a stale or unsolicited Qwen proposal cannot form or
dismiss a squad.

Once formed, `SquadManager` reapplies the relationship every few seconds. In
a human-led squad Goblin follows the authorized player and each additional
managed companion follows Goblin through the native `pathToCharacter` wrapper.
If the player disconnects, the squad is sent to the persisted base when one
exists. An NPC-led squad follows its managed native leader. The high-level
registry persists membership; the native adapter owns live body movement.
