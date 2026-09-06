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

The public projection is controlled without a code change through the
following environment settings:

```text
GOBLIN_TRACKER_ENABLED=true
GOBLIN_TRACKER_PRIVACY_MODE=exact      # exact, approximate, or hidden
GOBLIN_TRACKER_SHOW_PLAYERS=true
GOBLIN_TRACKER_SHOW_PLAYER_NAMES=true
GOBLIN_TRACKER_SHOW_EXACT_POSITIONS=true
GOBLIN_TRACKER_SHOW_NPCS=true
GOBLIN_TRACKER_HISTORY_ENABLED=true
```

`hidden` omits entity detail and `approximate` removes exact coordinates and
identity fields from the public projection while retaining bounded status
information. Exact coordinates remain available only to the private tracker
store and the server-to-tracker bridge.

## Website and map layer

`GET /` serves the small dependency-free tracker website. It consumes the
allowlisted state/events/history responses and the bounded SSE stream. The
browser map uses the Project Zomboid B42 `biomemap_<tile_x>_<tile_y>.png`
cache from the current server installation. The Python process never scans a
user-supplied path: `GOBLIN_TRACKER_MAP_ROOT` is an operator-configured,
read-only directory and tile coordinates must fall inside the manifest bounds.

The current live layer is Muldraugh P.O.T. for Build 42.20.4, with a 256-cell
tile size and tile bounds `x=0..77`, `y=0..62`. The tile coordinate is the
floor of the PZ world-cell coordinate divided by 256; the map canvas keeps
the same x-east/y-south orientation as the game. The manifest is served from
`web/map-manifest.json` through `/api/map/manifest` and identifies the exact
map build used for the cache.

The UI is deliberately observational. It can pan, zoom, focus the Goblin,
and fit the world, but it has no controls that write to the bridge, server,
save, or agent.
