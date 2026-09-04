# Migration from the native-client design

The old design depended on a Steam-authenticated PZ client, client-side Lua,
vanilla character creation, and ordered server/client Workshop parity. That
path is retired. `.76` is an agent/relay/Qwen/tracker host only; human players
use their own ordinary clients to join the server.

The replacement is a server-side NPC body created through Bandits2's verified
Build 42 API. Bandits2 remains the body and behavior engine; GoblinSurvivor
owns the Goblin-specific profile, friendly safety policy, chat, Qwen bridge,
and command policy. Joining clients need the server-advertised Bandits2 and
GoblinSurvivor Workshop dependencies, but `.76` still has no native client.
The only gameplay command is a typed `command.npc_action` message, and the
body-specific boundary is `NpcAdapter.lua`/`BanditsAdapter.lua`. Existing
saves remain in scope, but the server must be tested after each mod update and
unsupported engine capabilities must remain disabled.
