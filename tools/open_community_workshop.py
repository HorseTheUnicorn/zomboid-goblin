"""Open a separate, credited authoring copy of Community Rig v4.0.1.

The external rig stays in Downloads and is not part of the runtime mod. Blender
auto-run stays disabled; only the explicitly inspected, hash-pinned rig script
is registered for this Blender process. No user preferences are changed.
"""
import hashlib
from pathlib import Path
import runpy
import sys
import bpy
from mathutils import Quaternion

ROOT=Path(__file__).resolve().parents[1]
FOLDER=Path('C:/Users/tomgr/Downloads/Goblin-CommunityRig-v4.0.1')
SCRIPT=FOLDER/'PY-PZ_HumanRig.py'
OUTPUT=ROOT/'art/goblin/Goblin_Community_Workshop.blend'
if OUTPUT.exists() and '--rebuild' not in sys.argv:
    raise RuntimeError('Workshop already exists. Open it with register_community_controls.py; use --rebuild only to regenerate it.')
if hashlib.sha256(SCRIPT.read_bytes()).hexdigest()!='037a31bf278b111414856199e5596e1626d92d29abf52ce98e884f08d7197963':
    raise RuntimeError('Community rig script changed; inspect before running it')
bpy.ops.wm.open_mainfile(filepath=str(FOLDER/'PZ_HumanRigV4.blend'),use_scripts=False)
runpy.run_path(str(SCRIPT),run_name='__main__')
rig=bpy.data.objects['OBJ-HumanRig (0)']
body=bpy.data.objects['OBJ-MaleBody (0)']
print('COMMUNITY_BIND',[(n,list(map(list,rig.matrix_world@rig.data.bones[n].matrix_local)))
      for n in ('Bip01_Head','Bip01_L_Hand','Bip01_R_Hand')])
print('COMMUNITY_BOUNDS',[[min((body.matrix_world@v.co)[i] for v in body.data.vertices) for i in range(3)],
                        [max((body.matrix_world@v.co)[i] for v in body.data.vertices) for i in range(3)]])
rig.pz_human_props.model_sex='MALE'
rig.pz_human_props.controls_in_front=True if hasattr(rig.pz_human_props,'controls_in_front') else False
bpy.context.scene.pz_human_global_props.pz_directory='C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid'
with bpy.data.libraries.load(str(ROOT/'art/goblin/Goblin_Native_Comparison.blend'),link=False) as (available,loaded):
    loaded.objects=[n for n in available.objects if n.startswith('01 Original Goblin')]
for obj in loaded.objects:
    bpy.context.collection.objects.link(obj)
    obj.location.x=-1.1
rig.animation_data_create()
rig.animation_data.action=bpy.data.actions['Idle']
bpy.context.scene.frame_set(1)
info=bpy.data.texts.new('Goblin workshop - credits and scope')
info.write('Community Rig v4.0.1 by Paddlefruit.\n'
           'https://github.com/Paddlefruit/ProjectZomboid_CommunityRig\n'
           'Native models, textures and original armature: The Indie Stone.\n'
           'This is a separate LOCAL AUTHORING REFERENCE, not a deployed Goblin model.\n'
           'Left: original Goblin. Right: untouched community body and control rig.\n'
           'The custom rig UI is registered only in this process by the inspected source script.\n'
           'Open this file with tools/register_community_controls.py to register controls without changing auto-run preferences.\n')
for obj in bpy.context.selected_objects: obj.select_set(False)
rig.select_set(True);bpy.context.view_layer.objects.active=rig
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type=='VIEW_3D':
            area.spaces.active.shading.type='MATERIAL'
            area.spaces.active.region_3d.view_location=(-0.5,0,0.5)
            area.spaces.active.region_3d.view_distance=2.4
            area.spaces.active.region_3d.view_rotation=Quaternion((1,0,0),1.5707963)
            area.spaces.active.region_3d.view_perspective='ORTHO'
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'art/goblin/Goblin_Community_Workshop.blend'))
print('COMMUNITY_WORKSHOP_READY')
