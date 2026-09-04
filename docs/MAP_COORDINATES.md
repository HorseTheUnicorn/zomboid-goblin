# Map coordinates

## B42 tracker projection

The live tracker map uses the same world-cell coordinate system as the
Project Zomboid B42 server. The installed Muldraugh P.O.T. map metadata says
the map is fixed-2x and the map cache contains 256×256 `biomemap` tiles. For
the tracker layer, a game-cell coordinate `(x, y)` is drawn into tile

```text
tile_x = floor(x / 256)
tile_y = floor(y / 256)
pixel_x = x - tile_x * 256
pixel_y = y - tile_y * 256
```

The live cache inventory is 4,914 tiles (`78 × 63`), covering world cells
`x=0..19967` and `y=0..16127`. The tile image and canvas both use x increasing
eastward and y increasing southward; no y-axis inversion is applied. The
authoritative runtime values are in `web/map-manifest.json`.

The cache was copied from `.03`'s installed B42 map assets to
`/home/goblin/share/pz-map/b42/muldraugh` on `.76`. It is deliberately not
checked into Git. Refreshing the server's map version requires copying the
new cache, changing the manifest build/bounds, and restarting the tracker.

Exact `x/y/z` values are tracker telemetry. They may be stored for the live
map and Goblin history, but are not copied into `brain_view`, Qwen prompts,
model output, events, or semantic command labels. Numeric distance values are
also treated as a location side channel; coarse values such as `near`, `far`,
and `distance_bucket` remain available to cognition.
