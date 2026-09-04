# Settlement and jobs

The settlement model has a stable `base.primary` record and an explicit
minimum-guard floor. Jobs are an allowlist (`guard`, `patrol`, `scout`, `haul`,
`build`, `farm`, `loot`, `medic`, `quartermaster`, and `wander`). Job changes
are deterministic and reject unknown or unavailable NPCs.

Departure decisions must preserve the configured minimum base guards. Exact
base coordinates and construction targets belong to the server-side Lua
manager and tracker only; Qwen receives names and coarse zone labels.
