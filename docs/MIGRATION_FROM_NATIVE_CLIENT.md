# Migration from the native-client design

The old design depended on a Steam-authenticated PZ client, client-side Lua,
vanilla character creation, and ordered server/client Workshop parity. That
path is retired. `.76` is an agent/relay/Qwen/tracker host only; human players
use their own ordinary clients to join the server.

The replacement is a server-side Bandits NPC. The only gameplay command is a
typed `command.npc_action` message, and the only Bandits-specific code is
`BanditsAdapter.lua`. Existing saves and server Workshop configuration remain
in scope, but the server must be tested after each mod update and unsupported
Bandits capabilities must remain disabled.
