# Migration from the native-client design

The old design depended on a Steam-authenticated PZ client, client-side Lua,
vanilla character creation, and ordered server/client Workshop parity. That
path is retired. `.76` is an agent/relay/Qwen/tracker host only; human players
use their own ordinary clients to join the server.

The replacement is a server-side NPC body created through the documented Build
42 server Lua surface. Bandits2 informed the survivor-style behavior during
development, but it is not loaded by the server and is not required by
joining clients. The only gameplay command is a typed `command.npc_action`
message, and the body-specific boundary is
`NpcAdapter.lua`/`VanillaNpcAdapter.lua`. Existing saves remain in scope, but
the server must be tested after each mod update and unsupported engine
capabilities must remain disabled.
