# GoblinSurvivor Workshop publication

GoblinSurvivor is a self-contained mod. It has no external NPC framework or
required body-engine Workshop dependency.

The current unlisted GoblinSurvivor published-file ID is `3797127671`, owned by
`HorseTheUnicorn`. Verify that ID before changing any server loadout; do not
reuse the retired ID `3794624741`.

## Current staging package

The synchronized Windows staging folder is:

```text
C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor
```

It contains `workshop.txt`, `preview.png`, and
`Contents\mods\GoblinSurvivor\42`. The package must include the same
GoblinSurvivor files used by the local test profile.

## Publish or update an unlisted item

1. Use the already signed-in Steam account authorized for this project
   (`HorseTheUnicorn`) in the Windows PZ client.
2. Open Project Zomboid's Workshop Submit screen from the main menu.
3. Select the staging folder and choose the new-item path.
4. Set visibility to **Unlisted**, keep the title `GoblinSurvivor`, and use
   the repository `preview.png`.
5. Publish and complete Steam's Workshop legal-agreement prompt if shown.
6. Record the real numeric published-file ID in `workshop.txt`; never put
   credentials, tokens, or guard codes in the repository.

The current item is already published and verified at:

```text
https://steamcommunity.com/sharedfiles/filedetails/?id=3797127671
```

The repository preview is normalized to the PZ requirement of 256x256 pixels
and under 1000 KB. The published item is **Unlisted**.

## After publication

Add only the new GoblinSurvivor published-file ID to the dedicated server's
`WorkshopItems=` value and `GoblinSurvivor` to `Mods=`. Joining clients then
receive the same mod, including its chat-relay files. Restart only after the
bounded server backup described in `docs/DEPLOYMENT.md`, with no players
connected, and verify the bootstrap reports `selected_adapter=client_survivor`
and the Storm log identifies `HumanSurvivor` with `isZombie=false`.

The synchronized direct Windows package remains the local test path. `.76`
must never run a native PZ client or SteamCMD for gameplay.
