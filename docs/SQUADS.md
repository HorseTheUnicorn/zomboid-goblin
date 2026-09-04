# Squads and formations

Squads have a stable id, leader, bounded member list, and one of `line`,
`wedge`, `column`, `ring`, or `loose` formations. Selection excludes dead,
inactive, incapacitated, and critical workers and never drops the configured
base-guard floor. Formation offsets are semantic; Lua resolves them against
the live server state.

The model may request a squad. It cannot teleport, specify offsets as world
coordinates, or directly manipulate an NPC brain.
