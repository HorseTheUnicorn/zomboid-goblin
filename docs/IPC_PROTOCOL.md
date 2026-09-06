# IPC protocol

Every bridge message contains `protocol`, a bounded `request_id`, positive
`timestamp_ms`, and a constrained `type`. Files use the sequence
`<stem>.json` then `<stem>.ready`; readers only process complete validated
messages. Processed commands are acknowledged and archived, while malformed,
stale, duplicate, or unsupported messages are dead-lettered. Command
acknowledgements use the canonical lifecycle states `ACCEPTED`, `RUNNING`,
`SUCCESS`, `FAILED`, `REJECTED`, and `TIMEOUT`. Intermediate acknowledgements
are immutable records with a fresh acknowledgement id and a `command_id`
link; the terminal record keeps the command id as its filename for simple
relay consumers.

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

The final `response.command` is emitted only for a terminal result. A long
running movement, combat, or expedition command therefore produces
`ACCEPTED` and `RUNNING` acknowledgements first, then a terminal acknowledgement
and response when it completes or reaches its bounded timeout.
