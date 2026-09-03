# Operations and failure behavior

## Stop conditions

Leave the system in sensor-only mode when the PZ heartbeat is missing, stale, malformed, or from the wrong protocol version. Leave it paused when the body feasibility gate has not passed. The service does not retry an unsafe action by changing its target or by emitting lower-level instructions.

## Message lifecycle

A writer commits the JSON payload first and then its ready marker. Readers ignore files without both pieces. Valid commands are recorded in a bounded durable request ledger before a controller can act. Duplicate request IDs are archived without execution. Malformed, stale, unknown, and oversized items go to deadletter with a bounded reason.

## Observability

The runtime heartbeat contains only coarse status, body mode, feature flag, and age. The public status endpoint is an explicit allowlist containing alive, hunt_active, and prize_tier only. The admin endpoint requires a configured token and may show private diagnostic state. No endpoint returns raw model prompts, credentials, or arbitrary command text.

## Recovery

If a bridge channel is damaged, pause the service, preserve the archive and deadletter directories, fix the mount or permissions, then rerun the protocol tests. Do not delete the save to clear a bridge problem. Restore from the verified save backup only if the PZ test itself damaged the disposable copy.

