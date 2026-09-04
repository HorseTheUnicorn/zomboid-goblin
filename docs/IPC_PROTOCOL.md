# IPC protocol

Every bridge message contains `protocol`, a bounded `request_id`, positive
`timestamp_ms`, and a constrained `type`. Files use the sequence
`<stem>.json` then `<stem>.ready`; readers only process complete validated
messages. Processed commands are acknowledged and archived, while malformed,
stale, duplicate, or unsupported messages are dead-lettered.

Agent-to-PZ gameplay messages use only:

```json
{
  "protocol": 1,
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

Runtime state uses `runtime.state` for coarse cognition and
`runtime.exact_state` for tracker-only telemetry. The exact message is never
copied into the model context.
