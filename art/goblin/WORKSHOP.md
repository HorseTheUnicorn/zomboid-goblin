# Local Blender workshop

## Final in-game asset

`Goblin_Community_Final.blend` is the current authoring scene. It uses
Paddlefruit's Community Rig v4.0.1 for fitting, with the native human body and
black trousers as references. In game, Goblin uses Project Zomboid's own human
body, skeleton and four clothing items; only the custom head is exported. The
head is bound to `Bip01_Head` using the game's inverse bind matrix.

The body texture starts from the community rig's male UV layout, then is baked
onto the installed game's UV layout to correct differences around the hands.
The bake preserves the native alpha cutouts, including the gap between the legs.
`Goblin_Community_Final_report.json` records geometry checks and runtime hashes.

Rebuild against a local Project Zomboid 42.20.4 installation:

```powershell
& 'C:/Program Files/Blender Foundation/Blender 5.2/blender.exe' `
    --background --factory-startup --disable-autoexec --python-exit-code 1 `
    --python tools/build_goblin_community.py -- --render
python tools/stage_goblin_asset.py
```

Use `--community-rig PATH` and `--game PATH` after `--` for other local paths.
The builder does not execute embedded rig scripts. The staging command validates
the final head and skin hashes; it does not replace them with the old full-body
FBX. Original Goblin source files remain unchanged.

## Earlier authoring references

`Goblin_Community_Workshop.blend` is the Community Rig 4.0.1 authoring reference,
with the original Goblin alongside it. The rig, controls and supporting script
are by [Paddlefruit](https://github.com/Paddlefruit/ProjectZomboid_CommunityRig);
the original game armature, models and textures belong to The Indie Stone.
The upstream rig remains separately downloaded, with attribution intact. It is
not a dependency of the multiplayer Lua mod.

Open the saved workshop in Blender, registering the inspected controls only for
that process (without enabling global automatic script execution):

```powershell
& 'C:/Program Files/Blender Foundation/Blender 5.2/blender.exe' --disable-autoexec `
    art/goblin/Goblin_Community_Workshop.blend --python tools/register_community_controls.py
```

The controls helper expects the inspected v4.0.1 script in
`C:/Users/tomgr/Downloads/Goblin-CommunityRig-v4.0.1/`. Its hash is checked before
execution. The native-game asset importer in the community UI also requires
SaintBaron's DirectX importer; that extension has **not** been installed by this
work. See the upstream [asset setup instructions](https://github.com/Paddlefruit/ProjectZomboid_CommunityRig/wiki/Getting-Assets).

`Goblin_Native_Comparison.blend` is the separate walk/deformation test. Space plays
the installed game's Bob_Walk, frames 1–21. It contains Goblin's head on the native
body. The native coordinate space is Y-up and faces **−Z**, not +Z. This earlier
comparison is superseded by `Goblin_Community_Final.blend`; do not stage its
prototype assets.

`InspectPzMesh.java` imports assets using the installed PZ Assimp library and the
game's import flags plus structural validation. `build_native_workshop.py` checks
Blender deformation against native skin matrices at five walk-cycle keyframes.
Generated DirectX files use fixed-decimal floats because the bundled X parser
rejects exponent-only forms such as `-1e-06`.
