# Current work summary

Goblin has been migrated from the retired native-client concept to a
server-side persistent NPC. The Python side has a typed `NpcBodyDriver`,
semantic intent validator, deterministic entity/squad/base job managers, and a
bounded SQLite tracker. The Lua mod has a stable NPC registry,
protection/recovery hooks, a separate exact telemetry stream, and a
self-contained survivor-style adapter that creates and verifies a friendly
`Companion` profile.

The native PZ/Steam client artifacts were removed from `.76` without backups as
requested. The dedicated `.03` server remains active with the existing save and
GoblinSurvivor. Bandits2 remains only a development reference; it is not added
to the server or client loadout. The next deployment validates the
self-contained friendly body in-world. The current milestone also includes a
bounded nearest-zombie combat primitive, multiplayer chat input forwarding,
survivor-style/immortal hook guards, and a three-attempt delayed spawn retry
window so an async spawn failure cannot produce a horde.

Local checks currently cover strict bridge behavior, semantic coordinate
separation, NPC command publication, deterministic squad/job policy, and
tracker read-only routes.
