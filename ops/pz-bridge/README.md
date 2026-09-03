# PZ bridge provisioning

Run `provision_bridge.sh` on the Project Zomboid guest as root only after the
active server cachedir has been positively identified. It requires an explicit
path and refuses to create a guessed fallback root:

```sh
sudo ./provision_bridge.sh /home/zomboid/Zomboid/Lua/goblin-bridge
```

For a server started with a custom `-cachedir`, pass the corresponding
`<cachedir>/Lua/goblin-bridge` path instead. The cachedir and its `Lua`
directory must already exist below the `zomboid` service home.

The tool creates the eight bridge channels, the `.goblin-bridge-v1` marker,
`commands/.ready-index.json`, and a `config.ini` with `GoblinEnabled=false`.
It adds `zomboid` and `goblin` to the existing `goblinbridge` group and gives
`goblin` execute-only traversal on the parent directories. It never exports or
changes the Zomboid save files.

Restart the PZ service after provisioning so its supplementary group is active.
From `.76`, verify the marker and all channels through the existing key-only
SSH account before enabling the relay. Keep `GoblinEnabled=false` during that
test.

## Repair missing Build 42 media directories

Build 42's `AdvancedAnimator` scans `AnimSets` and `actiongroups` for every
enabled mod. A mod that supplies no custom animations must still have these
four empty directories, or the server can log `NoSuchFileException` during
startup. The repository includes a narrowly scoped root-only helper:

```sh
sudo ./ensure_mod_directories.sh /home/zomboid/Zomboid
```

The argument is the already verified PZ cachedir, not the `Lua` bridge root.
The helper requires the existing `mods/GoblinSurvivor` tree and its media
parents, refuses symlinks and file collisions, only creates missing
directories, and never replaces mod files or restarts the server. Restart the
PZ service separately after obtaining operator approval, then inspect the new
server log for any remaining Goblin-specific errors.
