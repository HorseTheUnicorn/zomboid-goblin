# Native Linux Goblin client

Goblin's actual Project Zomboid client belongs on 192.168.0.76. The Windows
installation and Workshop cache are source/evidence inputs only; Windows is not
the autonomous client. Wine is prohibited.

## Install with existing Steam ownership

The `.76` host already has the official SteamCMD bootstrap at
`/home/goblin/pz-client/steamcmd/`. Run the single guided setup command on
`.76` from a root terminal:

```sh
sudo /home/goblin/zomboid-goblin/ops/native-client/goblin-zomboid setup-steam
```

It prompts for the existing owning Steam account (default
`feralgoblin93k`), the Steam password through hidden input, any Steam Guard
code through a second hidden prompt, and the PZ server password through a
separate hidden prompt. The default PZ host is `192.168.0.3`; it is not
`192.168.0.2`. SteamCMD runs as the non-root `goblin` service account through
a PTY, so credentials do not appear in argv, shell history, or a log. The
setup writes `/etc/goblin-zomboid/secrets.env` atomically with mode `0600`
for that service account only after the native client is verified.

Do not source or paste the existing project `.env` into a shell. If its
values are being used, type them into the command's hidden prompts. The setup
command intentionally does not read that file automatically.

The `credentials` subcommand is an alias for `setup-steam`. Do not put a
password, Steam Guard code, cookie, or token in chat, a script, or this
repository.

After setup, use `check_secrets_metadata.sh` for a safe audit of the protected
file. It reports only mode, owner, size, and required key names; it never
prints credential values.

The setup does not create an account, buy a second copy, copy Windows Steam
state, or bypass DRM. It downloads the native Linux depot through Steam's
normal entitlement check. The verification requires the Build 42 launcher,
Java runtime, both networking libraries, `pzexe.jar`, and the game JAR before
the protected credential file is written. Afterward,
`check_native_client.sh` can be run as a separate read-only confirmation.

## Publish the GoblinSurvivor Workshop item

The server can make clients download GoblinSurvivor during the join flow only
after the mod has a real numeric Steam Workshop item ID. The repository now
contains a valid PZ `mod/workshop.txt` descriptor and a Linux-only publisher:

```sh
sudo /home/goblin/zomboid-goblin/ops/native-client/goblin-zomboid publish-workshop \
  --visibility unlisted
```

The default is the private-project-friendly `unlisted` visibility. It is
downloadable by its numeric item ID but not discoverable through global
Workshop searches. Use `--visibility public` only when the operator intends
the item to be searchable. The command writes only a mode-0600 VDF descriptor,
uses SteamCMD through a no-echo PTY, prompts for the Steam password and any
Steam Guard code interactively, and prints only the resulting non-secret item
ID.

After a successful upload, add that exact ID to the server's ordered
`WorkshopItems=` list while keeping `GoblinSurvivor` in `Mods=`. Verify the
downloaded Workshop tree against the reviewed SHA-256 before removing or
retiring any local staging copy. Do not upload until the Workshop visibility
has been explicitly selected.

The current unlisted item is `3794624741`. The publisher keeps the checked-in
authoring tree under `mod/Contents/mods/`, then creates a temporary upload
payload with `mods/` at the item root. SteamCMD uploads that payload verbatim;
this root-level layout is what the Build 42 client and dedicated server resolve
from their Steam Workshop caches. A clean Windows join has been verified to
download and load `GoblinSurvivor` from that layout with the reviewed digest.

## Start the native client

The native Steam client must be authenticated as `goblin` before the PZ
process can use Steam networking. After that UI login is complete, start the
client with:

```sh
/home/goblin/zomboid-goblin/ops/native-client/goblin-zomboid launch-client
```

The launcher is deliberately unprivileged and checks the complete Build 42
runtime, the same-user Steam process, and the configured display before
starting `ProjectZomboid64`. It does not accept arbitrary extra arguments and
does not put the PZ server password in argv or an environment variable; enter
that password through the normal PZ UI. Disabled systemd examples for a
software display, native Steam session, and PZ client are in
`systemd/goblin-steam-display.service.example`,
`systemd/goblin-native-steam.service.example`, and
`systemd/goblin-native-pz-client.service.example`. Enable those only after
Steam authentication and the full parity/body gates are complete.

## Stage the native client mod

After `check_native_client.sh` succeeds, run `install_goblin_mod.sh` on `.76`.
It copies only the GoblinSurvivor 42 mod into the native PZ user directory and
writes a SHA-256 sidecar used by the client parity report. The
`GoblinSurvivorSHA256` value in the server's
`<cachedir>/Lua/goblin-bridge/config.ini` must be set to the printed digest,
and the server's exact `Mods`/`WorkshopItems` lists must match the client's
loaded lists, before the body can be enabled.

## No-Steam fallback

Build 42.20.4's runtime accepts `-nosteam` and loads `ZNetNoSteam64`; this was
verified on an isolated native Linux dedicated server. That flag is not a
license bypass and does not make Windows files into Linux files. A real client
test may use it only after the native client files are legally present and the
server is configured for a compatible networking mode. Keep the live server
and Goblin disabled until the full multiplayer parity/body checklist passes.
