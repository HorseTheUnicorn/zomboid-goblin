# Goblin Project Zomboid integration

This repository contains the staged, safety-first integration for Project Zomboid.

The current scaffold is intentionally disabled by default. It provides a versioned file-bridge protocol, a heartbeat-only agent runtime, strict intent validation, state redaction, and a Build 42 mod shell. It does not move a survivor, issue gameplay commands, call an LLM, or change the existing Discord/agent service.

## Deployment topology

- Goblin brain host: 192.168.0.76
- Project Zomboid host: 192.168.0.3
- Bridge root on the PZ host: the PZ cachedir's `Lua/goblin-bridge`
  (normally `/home/zomboid/Zomboid/Lua/goblin-bridge` when `.3` uses its
  default cachedir)
- Read/write bridge mount on the Goblin host: /mnt/goblin-zomboid

The actual PZ guest and cachedir must be positively identified before the
bridge is provisioned or any service account is granted access. The physical
bridge directory must already exist on the PZ host; the agent and SSH relay
refuse to create a fallback root. The PZ mod uses the fixed relative bridge
root `goblin-bridge` because Build 42 resolves Lua file API paths below its
cachedir/Lua directory. Goblin-specific options live in
`Lua/goblin-bridge/config.ini`; Build 42 ignores unknown keys added to
`Server/<name>.ini`.

## Safety defaults

- GoblinEnabled is false until staged validation is complete.
- The model can produce only validated high-level intents.
- Coordinates, raw packets, Lua, shell, eval, and arbitrary code are rejected at the model boundary.
- Movement, combat, inventory, survival, and persistence remain deterministic controller responsibilities.
- A real multiplayer client must pass exact Build 42, Mods, WorkshopItems, and GoblinSurvivor content parity before it is a usable body.
- Vanilla character choices are discovered from the live client, streamed as bounded catalog metadata/chunks, selected by the personality layer, and applied by the deterministic client controller. Clothing and accessories are validated against the live vanilla item catalog.
- Goblin's real client runs on 192.168.0.76; the Windows machine is a source of
  content/cache evidence only.
- Wine, account spoofing, DRM bypassing, and unofficial Steam authentication
  workarounds are prohibited. The supported native-client operator path is in
  ops/native-client/.
- Malformed, stale, duplicate, oversized, and unknown messages fail closed.
- The planned CT100 path uses an SSH file relay because the PZ guest is an
  unprivileged LXC; NFS remains an optional, separately tested transport. The
  relay must not be enabled until the exact bridge path and Unix permissions
  are verified on the live guest.

See docs/ARCHITECTURE.md, docs/CLIENT_MOD_PARITY.md, and docs/BODY_FEASIBILITY_GATE.md for the staged design.
