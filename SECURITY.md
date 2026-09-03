# Security boundary

The threat model assumes that model output, PZ chat, player names, hunt clues, filenames, and remote web content are untrusted.

## Inbound model data

The model may propose only a typed high-level intent. IntentValidator checks JSON syntax, an exact root schema, mode-specific allowlists, target kinds, text limits, recursive forbidden keys, and the absence of coordinate-like values. Qwen output is rejected on any parsing or validation error.

## Game execution

The PZ side validates the message envelope and intent again. Controllers choose deterministic actions and own safety thresholds, cooldowns, combat, inventory, persistence, and proximity checks. There is no path from model text to Lua evaluation, shell execution, raw network packets, teleportation, or arbitrary PZ API calls.

The client body boundary is also fail-closed. The control plane compares the
server and client Build 42/mod manifests, including ordered `Mods=` and
`WorkshopItems=` values and the GoblinSurvivor content hash. It ignores a
client-supplied `verified` label when the manifests are absent or unequal.

## Bridge

The directory is private to the two hosts and split into channels. The planned
CT100 transport uses a dedicated non-sudo `goblin` SSH key on `.76`, limited by
Unix group permissions to the physical PZ cachedir/Lua bridge directory; it
does not expose the PZ save tree. The relay must remain disabled until that
path and access are verified. Once provisioned, it uploads JSON before the ready
marker and uses temporary names plus rename. The PZ Lua side uses its supported
`getFileWriter`/`getFileReader` API, writes JSON before ready, and has a
provisioned marker plus ready index because Build 42 does not expose `io`, lfs,
or directory enumeration to mod Lua. A JSON file is consumable only after the
ready marker exists. The request ledger makes command handling at-most-once;
stale, malformed, duplicate, unknown, or oversized items go to deadletter.

The native client setup is an interactive Linux-only command. Steam and PZ
server passwords are entered separately through hidden prompts; SteamCMD is
run as the non-root service account through a PTY, never with a password in
argv or environment. The setup writes only the protected
`/etc/goblin-zomboid/secrets.env` file after client verification, with mode
`0600`, and never reads the project `.env` automatically.

## Public and admin data

Public status is an allowlist and never includes coordinates, routes, exact distance, target labels, player location, or private diagnostics. Admin state requires a separately provisioned token and is intended to sit behind loopback binding and Cloudflare Access. Secrets are supplied through protected service credentials and never committed.

## Existing services

The current Discord, observatory, payout signer, and Qwen services are not modified by this repository. The Goblin integration runs as a separate service and must be stopped independently if its bridge or mod misbehaves.
