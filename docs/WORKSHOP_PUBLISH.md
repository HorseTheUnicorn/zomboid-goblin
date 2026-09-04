# GoblinSurvivor Workshop publication

GoblinSurvivor is our own mod. Bandits2 remains its required Workshop
dependency and is not copied into this repository.

The old GoblinSurvivor published-file ID `3794624741` is no longer available.
Do not add that ID to the server loadout. The current `.03` server uses the
direct package while the own mod is being republished.

## Current staging package

The synchronized Windows staging folder is:

```text
C:\Users\tomgr\Zomboid\Workshop\GoblinSurvivor
```

It contains `workshop.txt`, `preview.png`, and
`Contents\mods\GoblinSurvivor\42`. The package must include the same
GoblinSurvivor files as the server-side deployment.

## Publish an unlisted item

1. Use the Steam account authorized for the project (`djfubar33`) in the
   Windows PZ client.
2. Open Project Zomboid's Workshop Submit screen from the main menu.
3. Select the staging folder above and choose the new-item path. The previous
   published-file ID cannot be updated because Steam no longer has it.
4. Set the visibility to **Unlisted**, keep the title `GoblinSurvivor`, and
   use the repository `preview.png`.
5. Publish and complete Steam's Workshop legal-agreement prompt if shown.
6. Record the new numeric published-file ID; do not put credentials, tokens, or
   guard codes in the repository.

## After publication

The new ID must be appended to the dedicated server's `WorkshopItems=` value
alongside Bandits2 `3268487204`, while `Mods=` continues to load `Bandits2`
before `GoblinSurvivor`. Restart only after taking the bounded server backup
described in `docs/DEPLOYMENT.md`, then verify that a clean Windows client
downloads the exact published revision and that the server log reports
`adapter=bandits2 friendly=true control_ready=true`.

Until that ID is available, the synchronized direct Windows package is the
authoritative local test path. `.76` must never run a native PZ client or
SteamCMD for gameplay.
