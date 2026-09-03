# Goblin integration architecture

## Current stage

This repository starts with a disabled, heartbeat-only vertical slice. The existing Discord and agent application on 192.168.0.76 remains outside this repository and is not replaced. The new service must be run as a separate unit until the bridge and body feasibility gates pass. The intended PZ guest is 192.168.0.3. The planned CT100 bridge uses a private SSH file relay because the guest is an unprivileged LXC; it does not export the save directory. The relay remains disabled until the exact bridge path and Unix permissions are verified on the live guest.

Project Zomboid owns the game clock and deterministic body behavior. The Goblin service may request only a validated high-level intent. It never sends Lua, shell, eval, raw packets, coordinates, or arbitrary code.

An actual multiplayer client is part of the body boundary when Architecture B
is selected. The client is not ready merely because the server has
`GoblinSurvivor`; it must load the exact Build 42 revision, ordered `Mods=` and
`WorkshopItems=` lists, and matching GoblinSurvivor digest. The control plane
keeps `body_ready` false until those manifests compare as verified.

## Data flow

1. The PZ mod writes a versioned heartbeat and coarse state through the
   supported relative Lua file API to the pre-provisioned
   `<cachedir>/Lua/goblin-bridge` root.
2. The Goblin host reads the heartbeat and publishes its own heartbeat.
3. Later stages may turn coarse state and meaningful events into a model context.
4. Qwen proposes a JSON intent from a small allowlist.
5. A validator rejects malformed, stale, oversized, unknown, or unsafe fields.
6. Deterministic controllers translate the validated intent into game-safe actions.
7. Responses and acknowledgements are written with the same request ID.

On a fresh body, PZ supplies a catalog generated from its vanilla character
options. The personality prompt asks Qwen to choose a feral hippie/loot-goblin
appearance, traits, clothing, accessories, and other available cosmetics. The
Python and PZ deterministic controllers validate the catalog IDs and persist a
generation-tagged appearance manifest. Normal respawn reuses that manifest;
only confirmed character deletion enters the recreation boundary.

The model is never an executor. A controller may decline an intent because of distance, danger, inventory, permissions, cooldowns, or an unavailable body driver.

## Transport contract

The bridge is a pre-provisioned directory with state, events, commands,
responses, acks, runtime, archive, and deadletter channels, plus the
`.goblin-bridge-v1` marker. Python/relay writers use a temporary file in the
same directory, flush and fsync it, rename the JSON into place, then create a
ready marker. PZ Lua uses `getFileWriter`/`getFileReader`, writes JSON before
ready, and relies on the relay-maintained `commands/.ready-index.json` because
the PZ sandbox cannot enumerate directories. Readers process only a JSON file
with its ready marker.

Each message has protocol version 1, a bounded request ID, a millisecond timestamp, a bounded type, and a flat JSON body. Commands are at-most-once using a durable request ledger. Bad messages are moved to deadletter with a short reason. Completed messages are moved to archive. No bridge operation blocks the PZ tick on network or model inference.

## Safety boundaries

- GoblinEnabled defaults to false and is read from the provisioned relative
  `Lua/goblin-bridge/config.ini`; a missing or malformed file keeps it false.
- Goblin-specific settings are not placed in `Server/<name>.ini`, because
  Build 42 ignores unknown server-option keys.
- The bridge root is never silently created on the wrong host.
- The public hunt view is an explicit allowlist and contains no location data.
- Hunt clues are coarse and generated from candidate labels, not coordinates.
- Emergency survival is deterministic and can supersede social or hunt behavior.
- Location, combat, loot, and persistence controllers are separate from personality and dialogue.
- Character creation accepts only a runtime vanilla catalog; custom assets and
  model-selected executable behavior are rejected.
- The body gate requires exact server/client mod parity; a claimed parity flag
  without both manifests is ignored.

## Planned controllers

The next layers are reflex survival, tactical movement/combat, inventory/loot, social dialogue, memory/relationships, party travel, and the hunt state machine. Each layer must run against the disabled or sensor-only body first. Activation is staged only after tests, restart checks, duplicate-message checks, save-copy tests, and long-duration heartbeat checks pass.
