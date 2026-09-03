# Bridge protocol

All messages use a JSON object with this envelope:

- protocol: integer 1
- request_id: 1 to 128 safe filename characters
- timestamp_ms: positive Unix milliseconds
- type: bounded lower-case message type

Bodies are direct fields or a single object under payload, never both. The Python decoder bounds bytes, rejects non-JSON values, checks timestamps, and rejects mixed payload fields.

## Files

A Python writer writes a temporary file in the destination channel, flushes and
fsyncs it, renames the JSON file into place, then writes an empty ready marker
using the same atomic procedure. The native PZ Lua side cannot use `io`, lfs,
or `os.rename`; it uses Build 42's supported `getFileWriter` and
`getFileReader` with the relative `goblin-bridge` root. It writes the JSON
payload first and only then writes the ready marker. Readers reject malformed
or incomplete JSON and retry.

PZ Lua cannot enumerate a channel directory. The host relay therefore maintains
`commands/.ready-index.json` after publishing a command. The file is replaced
through an SSH temporary name plus rename, is bounded, and is ignored unless
the provisioned `.goblin-bridge-v1` marker and all channel directories exist.

Command lifecycle:

commands -> responses and acks -> archive

Invalid or stale lifecycle:

commands -> deadletter

Runtime heartbeat files are stable JSON without a ready marker. Python-side
copies are replaced atomically; the PZ-side writer is direct but bounded and
validated by the reader. They are treated as stale when older than the
configured PZ timeout.

## Message types

- runtime.heartbeat: process liveness and feature state
- state.snapshot: coarse structured state; no exact world data; a usable body
  also requires matching `server_mod_manifest` and `client_mod_manifest`
- event.name: meaningful event with an event-specific allowlist
- command.intent: validated high-level intent
- command.character_create: one-time, vanilla-catalog character proposal
- response.command: command outcome
- ack.command: command acknowledgement

The protocol layer does not authorize body fields by itself. The intent validator owns command semantics, and the PZ side validates again before any future body driver.

`command.character_create` carries a generation, a catalog version, and a
proposal containing only catalog option IDs. Qwen selects the proposal; the
deterministic character controller validates and persists it before publishing
the command. PZ must confirm the matching generation before the local lifecycle
becomes active. The appearance manifest is retained through ordinary death and
respawn; a new generation is permitted only when the actual character has been
deleted and recreation is required.

The vanilla character catalog is streamed as bounded runtime state rather than
placed in one large message. `state.catalog_meta` announces the catalog version,
catalog epoch, total chunk count, and option count. Each `state.catalog_chunk`
contains one ordered category slice and repeats the version, epoch, chunk index,
and total count. A reader accepts a catalog only after every index is present,
the epoch and version agree, the category slices are unique, and the assembled
option count matches the metadata. Missing, duplicate, stale, oversized, or
out-of-range chunks leave the catalog unavailable; they never partially enable
character creation. The Python side reassembles the complete catalog before
model selection, while the model receives only a compact bounded view when the
full catalog would exceed its context budget.

Catalog entries for clothing and accessories remain vanilla item IDs. An
accessory proposal is additionally tied to the catalog's vanilla body location
and full item type, so the client can instantiate and apply it through the
normal character-creation API. The client persists the accepted appearance and
does not reapply it on ordinary reconnect or respawn; recreation is the only
allowed appearance reset boundary.

For Architecture B, the runtime must not set a usable body based on a bare
`client_mod_parity` string. The Python side requires both exact manifests and
compares the Build 42 revision, ordered mod/workshop lists, and
GoblinSurvivor digest before `body_ready` can become true.
