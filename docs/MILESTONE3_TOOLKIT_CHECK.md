# Milestone 3 live toolkit check — September 26, 2026

Disposable goblin-local server PID 47324 (server-side Storm); client PID 36068,
m3path_61, without Storm. Gameplay source is unchanged from 33ac9dd. The
read-only probe inspected the actual managed actor inventory, without calling
ensureKit, adding/removing items, changing tasks, or moving the Goblin.

- Tick 401, st 743537375: each of the 29 Tools.types entries had exactly one
  reserved native inventory item; initial complete=true.
- Tick 702, st 743567418: all 29 still had one reserved copy;
  complete=true, reserved_identity_stable=true, elapsed_ms=30044.
- Identity comparison covered all reserved items in the inventory, in both
  directions. It was not merely a count comparison.

This proves live reserved-tool presence and identity stability during this
interval. It does not prove initial fuel emptying, acquired-fuel conservation,
condition repair, recipe consumption exclusion, delivery exclusion, inventory
replication, or save/reload persistence. Those remain separate acceptance gates.
The client was visibly in-world beside its Goblin; no UI input was necessary.

SHA-256:

- GoblinTools.lua: `1f506f3da845a3a7de8395991aa008a536534b0a69dbf89ca0df863e209d2abf`
- Probe: `7ae15ab25afba554b3159425b7f561f33ce2add39708c206164262599665a502`

Raw log: `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-toolkit-20260926.server.log`.
The staged server probe and enabling flag were removed after completion. The
source probe remains in tools/probes, outside the released mod. The local
server and client remain running. Production and published files are unchanged.
