# Current work summary

Goblin has been migrated from the retired native-client concept to a
server-side persistent NPC. The Python side has a typed `NpcBodyDriver`,
semantic intent validator, deterministic entity/squad/base job managers, and a
bounded SQLite tracker. The Lua mod has a stable NPC registry,
protection/recovery hooks, a separate exact telemetry stream, and a narrow
Bandits2 adapter that creates and verifies a friendly `Companion` profile.

The native PZ/Steam client artifacts were removed from `.76` without backups as
requested. The dedicated `.03` server remains active with the existing save and
GoblinSurvivor. The next deployment adds the published Bandits2 dependency to
the server loadout so Goblin can have a real friendly survivor body. The
vanilla body path remains fail-closed and is not used as a substitute.

Local checks currently cover strict bridge behavior, semantic coordinate
separation, NPC command publication, deterministic squad/job policy, and
tracker read-only routes.
