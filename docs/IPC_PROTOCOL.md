# IPC protocol

Every bridge message contains `protocol`, a bounded `request_id`, positive
`timestamp_ms`, and a constrained `type`. Files use the sequence
`<stem>.json` then `<stem>.ready`; readers only process complete validated
messages. Processed commands are acknowledged and archived, while malformed,
stale, duplicate, or unsupported messages are dead-lettered.

Agent-to-PZ gameplay messages use only:

```json
{
  "protocol": 2,
  "request_id": "npc-…",
  "timestamp_ms": 0,
  "type": "command.npc_action",
  "npc_id": "goblin.primary",
  "action": "FOLLOW",
  "priority": 1,
  "target": {"kind": "player", "player": "alice"}
}
```

Targets are semantic labels, never coordinates, routes, cells, chunks, paths,
building IDs, Lua, shell, or raw packets. The server validates the action a
second time and resolves it locally.

Explicit `OPEN_DOOR`/`OPEN_WINDOW`/`CLOSE_CURTAINS`, `FARM`, `CRAFT`, `REPAIR_VEHICLE`,
`ENTER_VEHICLE`, and `EXIT_VEHICLE` commands
require a one-use server-issued owner grant through the Python bridge. Direct
in-game orders obtain their identity from the native OnClientCommand player.
There are no caller-supplied coordinates or remote object IDs for these jobs.
`FARM.job` is plow/sow/water/harvest/tend; sow also takes `item.name` (crop).
`CRAFT.item.name` is an installed hand-recipe name and `item.count` is 1–10
batches. `REPAIR_VEHICLE.job` is all/engine/bodywork. These are explicit-owner
jobs, not additions to the offline model's autonomous capability allowlist.
Passenger orders take no model-supplied target, seat, vehicle ID, or coordinates.
Lua resolves them from the authenticated owner and native nearby vehicles. The
server-to-client companion roster carries the validated session binding and
entry/ride/exit phase; model telemetry contains only coarse transport status.

Chat events may include `direct_action`, `direct_applied`, `direct_detail`, and
`direct_reported`. Recognized but refused orders are still handled; the daemon
does not ask Qwen for a substitute action. If the server already reported the
result in-game, the daemon sends no duplicate reply and makes no model call.
Coarse state exposes work status and operation count, without job coordinates.

Runtime state uses `runtime.state` for coarse cognition and
`runtime.exact_state` for tracker-only telemetry. The exact message is never
copied into the model context.
