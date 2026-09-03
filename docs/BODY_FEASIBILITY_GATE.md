# Body feasibility gate

The Goblin brain is body-driver independent. Before implementing live autonomous behavior, prove which body architecture Project Zomboid supports in the installed Build 42 server.

## Client content precondition

Architecture B requires a real multiplayer client, not only a server mod. The
client must have the exact server Build 42 revision, complete ordered `Mods=`
and `WorkshopItems=` loadouts, and the same reviewed GoblinSurvivor content.
Both sides must publish manifests and the control plane must calculate
`client_mod_parity=verified`; a claimed status without matching manifests is
not evidence. Follow docs/CLIENT_MOD_PARITY.md before attempting the body
checks. A client that cannot load the complete server mod set cannot be used to
prove visibility or gameplay behavior.

## Architecture A: server-owned body

Choose this only when a disposable test save proves all of the following:

- a dedicated survivor is visible to multiplayer clients;
- it can move without client desynchronization;
- it can interact with containers, doors, and world objects;
- it can receive and deal damage through normal server rules;
- it can attack through normal animation and cooldown rules;
- inventory changes are visible and persist;
- death, respawn, and save/restart behavior are correct;
- the server remains responsive while the driver runs.

The spike must include at least two human clients observing the same body, an
exact client mod-parity record, a save/restart, and a negative test with
GoblinEnabled=false.

## Architecture B: actual PZ multiplayer client

Use this when a server-owned body cannot provide authoritative movement or interaction. The deterministic driver then runs in an actual game client session using the supported input and UI boundary. The client must still consume only validated high-level actions; it must not accept arbitrary Lua or shell from the model. The client must first pass the parity contract in docs/CLIENT_MOD_PARITY.md.

## Disposable probe result (2026-09-02)

An isolated native Linux Build 42.20.4 dedicated server was started on
192.168.0.76 with the `GoblinBodyProbe` mod and a disposable save. The probe
confirmed that `SurvivorFactory.CreateSurvivor`,
`SurvivorFactory.InstansiateInCell`, and the `IsoPlayer` constructor are
callable from server Lua. It did not produce a usable server-owned body:

- no world square was loaded without a connected client;
- the constructed `IsoSurvivor` reported `isExistInTheWorld=false`, had no
  square, and did not enter the survivor list;
- the constructed `IsoPlayer` could be marked NPC and named, but likewise had
  no square or world presence;
- the server Lua environment did not expose the `GameServer` registration
  collections needed to make the object a multiplayer player;
- a numeric Lua value could not be passed to the typed `short` online-ID API.

This is a failed Architecture A feasibility result, not an activation test.
It shows that constructing Java objects is insufficient; the server-owned
body still lacks the world, network, and player-registration lifecycle. The
live server was not changed and `GoblinEnabled=false` remains in force.

The same disposable native Linux server was started with `-nosteam`. Build
42.20.4 accepted the flag and loaded `ZNetNoSteam64`, logging `SteamUtils
started without Steam`. This verifies the official no-Steam networking path in
the installed runtime, but it is not yet proof that a real client can join the
Steam-mode live server. A legal native client installation and an end-to-end
client/server test are still required.

## Gate result

Do not select Architecture A from API names or a single-player experiment. Record the exact installed Build 42 version, the test save, client observations, logs, and restart result. Until the evidence exists, the shipped mode is sensor-only with body_present=false. If a client reports body_present=true without verified mod parity, the control plane keeps the body unavailable.
