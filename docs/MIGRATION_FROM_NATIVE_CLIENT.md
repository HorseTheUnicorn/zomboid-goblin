# Migration from the native-client design

The old design depended on a Steam-authenticated PZ client, client-side Lua,
vanilla character creation, and ordered server/client Workshop parity. That
path is retired. `.76` is an agent/relay/Qwen/tracker host only; human
players use their ordinary clients to join the server.

The current replacement is a server-authoritative client-rendered human actor.
The server publishes a bounded `IsoSurvivor` snapshot, and each joining client
creates a local `IsoSurvivor` from the normal survivor descriptor API. This
avoids the misleading legacy donor path where `IsoZombie.setAsSurvivor()` only
changed clothing. GoblinSurvivor owns the actor identity, snapshot authority,
client rendering, chat, persistence, and command policy. Joining clients need
GoblinSurvivor for the client actor and chat relay, but no separate NPC
framework or client account is required.

Development now happens against the local Windows Project Zomboid
installation and a disposable local test profile. The production `.03`
server is not restarted while this migration is being built. After local
spawn, friendly filtering, movement, speech, persistence, and death-recovery
checks pass, the native package can be staged for one guarded production
restart with no players online.
