# Tracker

`TrackerStore` retains exact map telemetry separately from the cognition
state. The Python `brain_view` removes exact coordinates while retaining safe
coarse labels and distance buckets. The tracker APIs are read-only:

- `GET /api/state`
- `GET /api/events`
- `GET /api/stream` (bounded SSE stream with an initial snapshot, live updates,
  keepalives, and reconnect-safe re-snapshots)
- `GET /api/history/goblin`
- `GET /api/map/manifest`
- `GET /api/health`

There are no public gameplay command, spawn, move, attack, or admin mutation
routes. Put authentication and TLS at the existing site/reverse proxy when
exposing the tracker beyond loopback.

## Website and map layer

`GET /` serves the small dependency-free tracker website. It consumes the
allowlisted state/events/history responses and the bounded SSE stream. The
browser map uses the Project Zomboid B42 player-map image pyramid from the
current server installation, not the biome diagnostic layer. The Python process never scans a
user-supplied path: `GOBLIN_TRACKER_MAP_ROOT` is an operator-configured,
read-only directory and tile coordinates must fall inside the manifest bounds.

The current live layer is Knox Country for Build 42.20.4, exported unchanged
from `media/maps/Muldraugh, KY/pyramid.zip` using `tools/export_native_map.py`.
Deploy the exported `native/` folder inside the configured map root and its
manifest as `web/map-manifest.json`. Five resolution levels use 256-pixel
tiles; world span is `256 * 2**level`. The canvas keeps
the same x-east/y-south orientation as the game. The manifest is served from
`web/map-manifest.json` through `/api/map/manifest` and identifies the exact
map build used for the cache.

The world bounds are 0..19968 east and 0..16128 south. This is static native
map imagery, not a live rendering of player-built structures. Additional map
mods require matching imagery. The export records the source archive SHA256.
World overview requests at most 20 tiles, the decoded-image cache is bounded
to 384 entries, and drag/wheel/image-load redraws are coalesced per frame.

The UI is deliberately observational. It can pan, zoom, focus the Goblin,
and fit the world, but it has no controls that write to the bridge, server,
save, or agent.

## CHVRCH host layout

The game and Storm run on `.03`. The existing SSH relay copies exact runtime
telemetry to `.76`, where `goblin-zomboid-agent` serves the tracker on port
8782. Deploy the complete `web/` directory alongside `goblin_zomboid/`; the
tracker needs both its assets and `map-manifest.json`. Map images remain at
`/home/goblin/share/pz-map/b42/muldraugh` on `.76`.

`ops/cloudflared-chvrch.service` runs the site's existing remotely managed
Cloudflare tunnel on `.76`. Provision its current token privately at
`/etc/cloudflared/chvrch.token` (root-owned, mode 0600); systemd passes it as a
service credential, not a command-line token. The Cloudflare hostname route
for `chvrch0fm3thany.xyz` must target the read-only tracker at
`http://192.168.0.76:8782`, never the admin API. Do not use the stopped Windows
tunnel for this site. An `Unauthorized: Tunnel not found` response requires
the current tunnel's valid credential, not repeated restarts.

Markers combine exact coordinates with companion roster names, distinguish
players from Goblins, and center on the first available position. Old source
timestamps are explicitly shown as last-known positions when the empty game
server pauses; fetching the tracker does not make old telemetry fresh.

The page is map-only, with top and bottom overlays. Top controls toggle player,
Goblin, and trail layers and select an entity to center on. Bottom controls
provide zoom, world fit, Goblin focus, coordinates, and source freshness.
The telemetry sidebar and chat/event panels are not displayed.

Focused checks: `node tests/test_web_map.cjs` and
`python -m unittest discover -s tests -p test_npc_tracker.py`.
