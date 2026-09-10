# Goblin PZ character asset

This directory is the source-of-truth character handoff for the Goblin
Companion. It contains the clean-room mesh skinned to the Project Zomboid
Mystery Rig (`Bip01`) and the preserved source textures:

- `Goblin_PZ_MysteryRig.blend` — normalized Blender authoring scene.
- `Goblin_PZ_MysteryRig.fbx` — selected-object FBX export for the Mystery Rig
  workflow.
- `Goblin_PZ_MysteryRig_report.json` — build counts, dimensions, weights, and
  export settings.
- `textures/` — the two 2048x2048 `Material_1` base-color PNGs used by the
  FBX, plus the supplied 1254x1254 `Goblin_Body_Atlas.png` and
  `Goblin_Head_Atlas.png` reference atlases.

The build report verifies a native-scale (~0.98 PZ scene-unit) mesh, complete
`Bip01` weight mapping, no unweighted vertices, and the intended animation
gate. The source character was authored at 1.70 m and is normalized to the
native survivor body scale during the final export. The armature bind
matrices are emitted in the same ~1.0-unit space as `MaleBody.x`; the old
`.01` parent scale is folded into the armature before FBX export, which avoids
the large runtime scale caused by a mesh/bind-space mismatch:

```text
Bob_Idle -> Bob_Walk -> Bob_Run -> Bob_Walk -> Bob_Idle
```

The released mod consumes Project Zomboid's native human rendering and
animation contract: one networked `IsoZombie`, `Survivor` outfit
humanization, and the Goblin `Bob_*` AnimSets. The FBX is packaged as the
`Goblin_MysteryBody` `base:underwear` clothing resource with adjacent `.fbm`
textures; `GoblinBody.lua` adds and wears that real item on spawn/restore, so
the normal clothing replication path carries the mesh to clients. The Blend
scene remains the authoring source, while a live client/server render pass is
still required to verify the final shader/scale in every B42 point release.

The supplied body/head atlases are retained as source references and are
copied into the package's `textures/Goblin_PZ_MysteryRig/source/` folder. They
use a different UV island layout from the current mesh, so assigning either
one directly would produce the patchwork texture seen in a Blender test
render; the packaged `Material_1_basecolor.png` remains the mapped diffuse
image until a deliberate UV remap is performed.
