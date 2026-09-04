# Settlement and jobs

The settlement model has a stable `base.primary` record and an explicit
minimum-guard floor. The base anchor is set server-side with the exact
in-game command `!goblin base set` (or `/goblin base set`) by a PZ admin,
moderator, or username listed in `GoblinCommanders=`. The exact anchor is
stored in server ModData and is never sent to Qwen. An unprivileged player
cannot redefine it.

Jobs are an allowlist (`guard`, `patrol`, `scout`, `haul`, `build`, `farm`,
`loot`, `medic`, `quartermaster`, and `wander`). Job, squad, and base-security
mutations require a short-lived, one-use authority grant minted by the
server when an authorized commander asks Goblin in chat. The grant is carried
through the private bridge but is not included in the Qwen context; the Lua
command loop rejects privileged actions without a server-minted grant.

Departure decisions must preserve the configured minimum base guards. Exact
base coordinates and construction targets belong to the server-side Lua
manager and tracker only; Qwen receives names and coarse zone labels.
