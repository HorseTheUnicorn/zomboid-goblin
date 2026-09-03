# Goblin Project Zomboid Integration — Work Summary

## Scope and topology

- Goblin's native Linux Project Zomboid client runs on `192.168.0.76`.
- The dedicated Project Zomboid server runs in Proxmox CT100 on `192.168.0.3`.
- The Proxmox host is `192.168.0.39`.
- The Windows machine is an administration and VNC browser only; it is not the game client.
- The client uses the native Steam Build 42 installation. Wine, DRM bypassing, account spoofing, and unofficial authentication were not added.
- The existing Discord/agent system remains a separate service. Goblin's daemon, SSH file relay, and admin service are separate components.

## Work completed

1. Read and applied the final build plan and the persistent goal requirements.
2. Validated the native Linux Steam/PZ client on `.76`, including the saved multiplayer profile and connection to the dedicated server.
3. Used the existing VNC/noVNC display on `.76` for visual verification. The observed noVNC endpoint is:
   `http://192.168.0.76:6080/vnc.html?host=192.168.0.76&port=6080`
4. Restored the clean `GoblinSurvivor` server/client Lua copies after temporary diagnostics caused a checksum mismatch. The active clean `CommandLoop.lua` copies matched SHA-256:
   `BA2FEB25BC65E608AA618EE8044A370D6D21A54E36C9E5ACD710CAB08B938B81`
5. Restarted only `zomboid-servertest.service`. The Proxmox host, CT100, world save, and character save were not reset.
6. Verified that the dedicated server process started successfully and listened on UDP `16261` and `16262`.
7. Verified that the existing character `Pierre Bolden` remained in-world after reconnecting the native client.
8. Added durable command-processing markers in `IPC.lua`. Processed commands now receive `.processed.json` metadata, and archival no longer depends on reading a host-created zero-byte `.ready` marker.
9. Added validated JSON-only fallback handling for PZ-generated `events` and `responses` in `goblin_zomboid/relay.py`. Command input remains marker-gated.
10. Kept the structured-intent security boundary. Arbitrary shell, Lua, code, raw packets, coordinates, teleport, and similar fields remain rejected.
11. Kept credentials out of source, logs, dashboard output, and command examples. Password values were not printed or committed.

## Last verified live state

The dedicated server service and PZ process were running. The bridge state reported:

```text
GoblinEnabled=true
body_mode=live_client
body_present=true
alive=true
character_state=active
client_control_ready=true
client_mod_compatibility=compatible
```

The runtime also reported `client_mod_parity=mismatch`, because the ordered WorkshopItems loadout differs even though the control-compatibility check passed.

## Known incomplete work

The full integration is not complete yet.

- A pending structured `SAY` command exists in the server bridge queue but has not yet been consumed, acknowledged, or archived. The next debugging target is the server-side `IPC.listReady()` / `IPC.readFile()` path or the event path invoking `CommandLoop.tick()`; another full server restart is not justified merely to inspect this.
- Goblin has not yet been validated creating his first character through vanilla character creation.
- The existing saved character is `Pierre Bolden`; the required fresh-character personality selection and deterministic application of appearance, clothing, traits, accessories, and cosmetics remain to be completed.
- Deterministic movement, combat, loot, survival, party, hunt, reward, speech, and death/recreation behavior still require implementation and live acceptance tests.
- The current configured body username is `feralgoblin93k`; the final design describes the in-game identity as `Goblin`. Changing this must be planned around the existing saved character rather than done by an unsafe reset.
- Interactive Steam/PZ credential bootstrap, Steam Guard pause/resume, protected `/etc/goblin-zomboid/secrets.env` creation, and reconfiguration commands still require end-to-end validation.
- The private admin map and Cloudflare Access boundary still require final deployment and verification.
- Nonfatal missing animation/bone and other installed-mod warnings remain in the PZ logs and should be reviewed before final acceptance.

## Validation performed

- Python unit tests previously completed: `78` tests passed.
- Python bytecode compilation previously completed successfully with:
  `python -m compileall -q goblin_zomboid ops tests`
- Native client process, relay process, daemon process, VNC endpoint, server service, PZ process, ports, server-start log, bridge state, and saved-character persistence were checked live.
- Lua changes were verified by matching active server/client file hashes and by reconnecting the native client without a new checksum kick.

## Operational cautions

- Do not delete or clear the bridge command queue while diagnosing the unconsumed command.
- Any Lua mod change must be installed consistently on the server and native client before reconnecting, or PZ checksum protection can reject the client.
- Do not put Steam, PZ, Steam Guard, or VNC passwords in shell commands, history, logs, Discord, or the web dashboard.
- Do not stop CT100 or the dedicated server solely because the PZ UI displays an external-port warning; the authoritative CT check showed the server sockets listening.
