# Tracker

`TrackerStore` retains exact map telemetry separately from the cognition
state. The Python `brain_view` removes exact coordinates while retaining safe
coarse labels and distance buckets. The tracker APIs are read-only:

- `GET /api/state`
- `GET /api/events`
- `GET /api/stream` (bounded SSE snapshot)
- `GET /api/history/goblin`
- `GET /api/health`

There are no public gameplay command, spawn, move, attack, or admin mutation
routes. Put authentication and TLS at the existing site/reverse proxy when
exposing the tracker beyond loopback.
