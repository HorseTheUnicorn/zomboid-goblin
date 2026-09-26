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

## Native repair follow-up on e4a9fb9

Disposable server PID 39184, no-Storm client PID 10032 (m3path_61).
All five local package copies received the repair-readback fix before restart.
This run used explicit `repair-hammer` mode, not the earlier read-only mode.

- Tick 230: all 29 tool types had one reserved copy.
- Same tick: actual hammer ID 278240023 was temporarily set to condition 9;
  Tools.ensure returned that exact item with native condition 10. The probe
  asserted the inventory size was unchanged.
- Same tick: original condition restored successfully, including native readback.
- Tick 531: complete=true, reserved_identity_stable=true after 30035 ms.

This validates the native repair success path and reserved-item stability for
the current implementation. Fuel conservation, delivery/recipe exclusion and
save/reload tests remain separate. No two-client inventory claim is made.

SHA-256 of GoblinTools.lua:
`261b68bd755d0542ad6e2f9045d526f4d63bd68e969daba7867de46f32732f39`.
Probe SHA-256:
`0ed4942d3fc122070d73696ca7987a35e71a1f5b7eacfe91c1a780f6de08d24d`.
Raw log: `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-toolkit-repair-20260926.server.log`.
The staged probe and enabling flag were removed after the terminal sample.
Three probe-control tests pass, including condition restoration after a failed
repair. These mocks test cleanup logic, not native repair behavior.

## Native acquired-fuel preservation on 3496342

Disposable server PID 54604, no-Storm client PID 4516 (m3path_61).
Gameplay GoblinTools.lua is unchanged from e4a9fb9. The explicit
`fuel-conservation` fixture temporarily seeded partial contents in the existing
reserved Base.BlowTorch, ran Tools.ensure, then restored its previous fuel and
condition with readback. No additional tool was created.

- Tick 274: native torch ID 650595693 retained fuel 0.5 -> 0.5; same object
  returned and inventory count unchanged. fuel_fixture_restored=true.
- Tick 574: all 29 configured reserved copies present and native identities
  stable over 30000 ms.

This proves maintenance preserves existing drainable contents. It does not
prove real propane transfer, initial empty-tool creation, fuel consumption in
welding, fluid-container behavior, client inventory replication or save/reload.
The fixture is test-only, not an unlimited-fuel gameplay feature.

Installed references: `media/scripts/generated/items/drainable.txt` defines
Base.BlowTorch as base:drainable with KeepOnDeplete=true; installed
`media/lua/server/ClientCommands.lua` uses getCurrentUsesFloat/setUsedDelta
to read and change drainable contents.

Probe SHA-256:
`da17d6cace2329ae275772fb5b19324ed12affa2e9c6201265154ede1a222cc9`.
Raw log: `C:\Users\tomgr\Zomboid\goblin-test-backups\m3-toolkit-fuel-20260926.server.log`.
Four probe-control tests pass, including restoration after simulated unwanted
refilling. Staged probe and flag removed after final sample.
