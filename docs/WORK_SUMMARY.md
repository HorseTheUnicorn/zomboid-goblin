# Current work summary

Goblin has been migrated from the retired native-client concept to a
server-side persistent Bandits NPC. The Python side now has a typed
`NpcBodyDriver`, semantic intent validator, deterministic entity/squad/base
job managers, and a bounded SQLite tracker. The Lua mod has a stable NPC
registry, protection/recovery hooks, a separate exact telemetry stream, and a
fail-closed Bandits adapter using the APIs inspected from Workshop item
`3268487204`.

The native PZ/Steam client artifacts were removed from `.76` without backups as
requested. The dedicated `.03` server remains active with the existing save,
GoblinSurvivor, and Bandits 2 installed. Bandits startup still needs an
in-world validation pass because its Linux server log contains missing
animation-asset warnings; those warnings must not be hidden by the adapter.

Local checks currently cover strict bridge behavior, semantic coordinate
separation, NPC command publication, deterministic squad/job policy, and
tracker read-only routes.
