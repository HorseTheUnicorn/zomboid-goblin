# Current work summary

Goblin has been migrated from the retired native-client concept to a
server-side persistent NPC. The Python side has a typed `NpcBodyDriver`,
semantic intent validator, deterministic entity/squad/base job managers, and a
bounded SQLite tracker. The Lua mod has a stable NPC registry,
protection/recovery hooks, a separate exact telemetry stream, and an original
vanilla adapter that does not require Bandits or another Workshop framework.

The native PZ/Steam client artifacts were removed from `.76` without backups as
requested. The dedicated `.03` server remains active with the existing save and
GoblinSurvivor. The server is now configured without the Bandits Workshop
dependency; its cached package was left untouched. The vanilla body still
needs an in-world multiplayer validation pass with a real player connection.

Local checks currently cover strict bridge behavior, semantic coordinate
separation, NPC command publication, deterministic squad/job policy, and
tracker read-only routes.
