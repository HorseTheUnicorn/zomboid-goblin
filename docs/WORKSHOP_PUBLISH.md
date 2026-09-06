# GoblinSurvivor Workshop publication

GoblinSurvivor is a self-contained mod. It has no external NPC framework or
required body-engine Workshop dependency.

The old GoblinSurvivor published-file ID `3794624741` is no longer available.
Do not add that ID to the server loadout. The current `.03` server remains on
its existing package until the native engine passes local testing.

## Current staging package

The synchronized Windows staging folder is:

```text
C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor
```

It contains `workshop.txt`, `preview.png`, and
`Contents\mods\GoblinSurvivor\42`. The package must include the same
GoblinSurvivor files used by the local test profile.

## Publish an unlisted item

1. Use the already signed-in Steam account authorized for this project
   (`HorseTheUnicorn`) in the Windows PZ client.
2. Open Project Zomboid's Workshop Submit screen from the main menu.
3. Select the staging folder and choose the new-item path.
4. Set visibility to **Unlisted**, keep the title `GoblinSurvivor`, and use
   the repository `preview.png`.
5. Publish and complete Steam's Workshop legal-agreement prompt if shown.
6. Record the new numeric published-file ID; never put credentials, tokens, or
   guard codes in the repository.

## After publication

Add only the new GoblinSurvivor published-file ID to the dedicated server's
`WorkshopItems=` value and `GoblinSurvivor` to `Mods=`. Joining clients then
receive the same mod, including its chat-relay files. Restart only after the
bounded server backup described in `docs/DEPLOYMENT.md`, with no players
connected, and verify the bootstrap reports `selected_adapter=client_survivor`
and the Storm log identifies `HumanSurvivor` with `isZombie=false`.

Until publication, the synchronized direct Windows package is the
authoritative local test path. `.76` must never run a native PZ client or
SteamCMD for gameplay.
