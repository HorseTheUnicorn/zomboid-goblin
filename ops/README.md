# Host templates

These files are templates only. The PZ account UID/GID, transport availability,
save path, and package policy must be verified on the live guest before use.

The planned CT100 deployment uses `goblin_zomboid.relay` over the dedicated
key-only `goblin` account. The relay root is the physical directory matching
the PZ server's relative `GoblinBridgeRoot`, normally
`/home/zomboid/Zomboid/Lua/goblin-bridge` when the server uses its default
cachedir. The export example is intentionally disabled. The relay must not be
enabled until the path and group permissions are verified on `.3`. Do not
substitute the Zomboid save directory.

The root-only bridge helper is `ops/pz-bridge/provision_bridge.sh`; it requires
an explicit verified `<cachedir>/Lua/goblin-bridge` path and does not create a
fallback directory.
