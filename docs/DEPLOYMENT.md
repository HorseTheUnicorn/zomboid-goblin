# Deployment and activation runbook

This runbook is deliberately staged. It is not an instruction to enable autonomous gameplay.

## 1. Identify the guest

The intended PZ guest is the live Proxmox LXC at 192.168.0.3. Confirm its hostname, installed Build 42 version, save directory, and active server service from the Proxmox console before changing files. Do not assume that a container ID or an IP alone proves the game service.

The existing Goblin host is 192.168.0.76. Its cave application, Discord service, and local Qwen service are separate and must remain running.

## 2. Protect the save

Make a timestamped backup of the PZ save and server configuration. Verify that the backup is readable before installing the mod. Keep `GoblinEnabled=false` in the bridge `config.ini`. First tests use a disposable copy, not the live save.

## 3. Provision the bridge on the PZ guest

Create the physical bridge root below the PZ server's cachedir/Lua directory
and only these child directories:

state
events
commands
responses
acks
runtime
archive
deadletter

For the current `.3` start command, which does not specify `-cachedir`, verify
the default cachedir first; the expected physical path is normally
`/home/zomboid/Zomboid/Lua/goblin-bridge`. The mod uses the fixed relative
root `goblin-bridge`, not the physical path. Create the marker
`.goblin-bridge-v1`, `commands/.ready-index.json` containing `[]`, and the
disabled `config.ini` at that root before starting the mod.

The repository includes `ops/pz-bridge/provision_bridge.sh` as a root-only
helper for this step. It requires the operator to pass the already verified
`<cachedir>/Lua/goblin-bridge` path and refuses guessed or symlinked roots.

The CT100 guest is an unprivileged LXC, so the planned deployment uses an SSH
file relay rather than starting an NFS server inside the container. Create a
dedicated `goblinbridge` group, grant only `zomboid` and the non-sudo `goblin`
account access to this exact Lua bridge directory, and do not expose the
Zomboid save directory. The `.76` relay authenticates as `goblin` with its
existing host-local key and copies JSON before its ready marker. A read-only
check on 2026-09-02 found the live PZ process running as `zomboid` but did not
find a bridge readable by `goblin`; do not enable the relay until a privileged
operator provisions and verifies the bridge path and group permissions.

## 4. Configure the relay on the Goblin host

Create `/mnt/goblin-zomboid` as a pre-provisioned local relay root and install
`systemd/goblin-zomboid-relay.service.example`. Run the relay once and verify
that a test heartbeat written on the PZ guest appears locally and that a test
command written locally appears on the PZ guest. The relay refuses to create
the remote root and the agent refuses to treat a stale local copy as live PZ.

Install the example systemd unit only after this check. Keep GOBLIN_ENABLED=false. Keep the admin API bound to 127.0.0.1 and put any public access behind the existing private access layer and Cloudflare Access. Do not put an admin token in the repository.

## 5. Install the server mod and capture the client contract

Install the GoblinSurvivor mod in the disposable Build 42 server. Put the
Goblin-specific settings in `<cachedir>/Lua/goblin-bridge/config.ini`; do not
add `GoblinEnabled` or other Goblin keys to `Server/<name>.ini`, because Build
42 ignores unknown options. Keep `GoblinEnabled=false`. Restart the disposable
server and verify that the heartbeat and state are written below
`<cachedir>/Lua/goblin-bridge`. A missing marker, bridge, config, or JSON codec
must result in no body behavior.

Capture the exact server `Mods=` and `WorkshopItems=` values and the reviewed
GoblinSurvivor tree digest. A Goblin multiplayer client must install the full
server loadout, not just GoblinSurvivor. Follow docs/CLIENT_MOD_PARITY.md; a
normal PZ client download prompt is not proof that the autonomous client has
the required content.

## 6. Client parity and body feasibility gates

Run the client-parity test in docs/CLIENT_MOD_PARITY.md and the
body-feasibility test in docs/BODY_FEASIBILITY_GATE.md. Prove multiplayer
visibility, movement, interaction, damage, attack, inventory, persistence, and
restart behavior with at least two observing clients. If the server-owned body
fails any item, stop and use an actual supported multiplayer client driver.
Do not paper over a failed authoritative-body or client-parity test.

The current disposable server-only probe has already failed the Architecture A
gate: Build 42 can construct Java body objects, but without a connected client
they do not acquire a world square or multiplayer player registration. Follow
`ops/native-client/` for the native Linux client path on `.76`. Do not use
Wine, copy Windows Steam credentials, or treat the Windows client as Goblin's
body.

Before any client join test, run the guided native setup on `.76`:

```sh
sudo /home/goblin/zomboid-goblin/ops/native-client/goblin-zomboid setup-steam
```

The command prompts for Steam credentials and the PZ server credentials
separately, with hidden input, pauses for Steam Guard when needed, installs
Build 42 app `108600` as the non-root `goblin` account, verifies the native
Linux files, and then writes `/etc/goblin-zomboid/secrets.env` mode `0600`.
The project `.env` is not sourced or read automatically.

## 7. Activation order

1. Disabled heartbeat on disposable save.
2. Sensor-only state and event feed.
3. Validator and controller tests with a fake body.
4. Deterministic body movement with no model.
5. Combat, inventory, and survival emergency tests.
6. Qwen intent proposals with strict rejection tests.
7. Party travel and hunt tests with duplicate-claim and relocation tests.
8. Long-duration restart and save-copy test.
9. Exact client mod parity and a multiplayer join/reconnect test.
10. Only then consider changing GoblinEnabled, one stage at a time, with a manual rollback ready.

The admin resume control cannot override GoblinEnabled=false. A false master flag is always the stronger stop.
