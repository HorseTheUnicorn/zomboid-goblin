"""Author Goblin on Paddlefruit's Community Rig; export only the custom head.

The game keeps its own human body, bind pose, UVs and clothing. The head uses
native PZ inverse binds, not the community rig's control/helper bones. Run with
Blender --background --factory-startup --disable-autoexec --python this_file.
Optional arguments after --: --community-rig PATH --game PATH --render.
The referenced rig is not modified and none of its embedded scripts execute.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys

import bpy
import bmesh
from mathutils import Matrix, Quaternion, Vector

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).parent))
from pz_x_mesh import read_mesh, write_mesh

parser = argparse.ArgumentParser()
parser.add_argument('--community-rig', type=Path, default=Path('C:/Users/tomgr/Downloads/Goblin-CommunityRig-v4.0.1/PZ_HumanRigV4.blend'))
parser.add_argument('--game', type=Path, default=Path('C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid'))
parser.add_argument('--render', action='store_true')
args = parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
MEDIA = ROOT/'mod/Contents/mods/GoblinSurvivor/common/media'
ART = ROOT/'art/goblin'
QA = ART/'qa'
native = read_mesh((args.game/'media/models_X/Skinned/MaleBody.x').read_text())


def material(name, image):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    node = mat.node_tree.nodes.new('ShaderNodeTexImage')
    node.image = image
    node.interpolation = 'Closest'
    shader = mat.node_tree.nodes.get('Principled BSDF')
    shader.inputs['Roughness'].default_value = 0.85
    mat.node_tree.links.new(node.outputs['Color'], shader.inputs['Base Color'])
    return mat, node


def active(obj):
    for selected in bpy.context.selected_objects:
        selected.select_set(False)
    obj.hide_set(False)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def mesh_object(name, vertices, faces, uv):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    layer = mesh.uv_layers.new(name='PZ UV')
    for loop in mesh.loops:
        layer.data[loop.index].uv = uv[loop.vertex_index]
    for face in mesh.polygons:
        face.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


# Extract the authored head with UV seams intact, before opening the rig.
bpy.ops.wm.open_mainfile(filepath=str(ART/'Goblin_PZ_MysteryRig.blend'), use_scripts=False)
source = bpy.data.objects['Goblin_Mesh']
source.data.calc_loop_triangles()
groups = {g.index:g.name for g in source.vertex_groups}
ids = {v.index for v in source.data.vertices if any(groups[g.group]=='Bip01_Head' and g.weight>0.5 for g in v.groups)}
top = max((source.matrix_world@source.data.vertices[i].co).z for i in ids)
vertices, faces, uv, remap = [], [], [], {}
for tri in source.data.loop_triangles:
    if not all(i in ids for i in tri.vertices):
        continue
    face = []
    for i, loop in zip(tri.vertices, tri.loops):
        coord = tuple(source.data.uv_layers.active.data[loop].uv)
        key = (i, coord)
        if key not in remap:
            p = source.matrix_world@source.data.vertices[i].co
            remap[key] = len(vertices)
            # Community viewport: Z-up, nose toward -Y. PZ X is Y-up, -Z.
            vertices.append((-p.x*0.8, p.y*0.8+0.02, 0.99+(p.z-top)*0.8))
            uv.append(coord)
        face.append(remap[key])
    faces.append(list(reversed(face)))  # viewport conversion reflects X

bpy.ops.wm.open_mainfile(filepath=str(args.community_rig), use_scripts=False)
scene = bpy.context.scene
rig = bpy.data.objects['OBJ-HumanRig (0)']
body = bpy.data.objects['OBJ-MaleBody (0)']
base_skin = bpy.data.images['TEX-DefaultMale']
rig.data.pose_position = 'REST'
for obj in scene.objects:
    obj.hide_render = obj not in (rig, body)
body.hide_set(False)
body.hide_viewport = False
# The upstream geometry-node material needs its add-on. Retain its armature
# and the actual community mesh/UVs, replacing only the material setup.
for mod in list(body.modifiers):
    if mod.type != 'ARMATURE':
        body.modifiers.remove(mod)

# Verify community body vertices and UV corners against the installed game.
# Native has additional dress panels; the community base body omits those.
native_pairs = [(Vector((p[0],p[2],p[1])), Vector((u,1-v)))
                for p,(u,v) in zip(native.vertices,native.uv)]
uv_errors, position_errors = [], []
for loop in body.data.loops:
    p = body.matrix_world@body.data.vertices[loop.vertex_index].co
    u = body.data.uv_layers.active.data[loop.index].uv
    candidates = [(n,nu) for n,nu in native_pairs if (p-n).length < 0.00001]
    if not candidates:
        raise RuntimeError(f'Community body vertex differs from installed PZ: {tuple(p)}')
    position_errors.append(min((p-n).length for n,_ in candidates))
    uv_errors.append(min((u-nu).length for _,nu in candidates))
# Community v4 adjusts hand UVs and a few triangulation diagonals. A surface
# bake transfers its material to the installed UVs without assuming corner IDs.
def point_key(p):
    return tuple(round(float(v),4) for v in p)

community_points = {point_key(body.matrix_world@v.co) for v in body.data.vertices}
native_points = [point_key((x,z,y)) for x,y,z in native.vertices]
bake_faces = [list(reversed(f)) for f in native.faces if all(native_points[i] in community_points for i in f)]

# Bake a green skin MATERIAL over the rig's unmodified native texture/UVs.
# This is shader baking, not a replacement atlas or a guessed UV unwrap.
skin_mat, skin_node = material('Goblin - Community Rig native skin', base_skin)
nodes, links = skin_mat.node_tree.nodes, skin_mat.node_tree.links
luma = nodes.new('ShaderNodeRGBToBW')
links.new(skin_node.outputs['Color'], luma.inputs['Color'])
ramp = nodes.new('ShaderNodeValToRGB')
ramp.color_ramp.elements[0].position = 0.0
ramp.color_ramp.elements[0].color = (0.015,0.022,0.003,1)
ramp.color_ramp.elements[1].position = 0.8
ramp.color_ramp.elements[1].color = (0.40,0.47,0.095,1)
links.new(luma.outputs['Val'], ramp.inputs['Fac'])
emission = nodes.new('ShaderNodeEmission')
links.new(ramp.outputs['Color'], emission.inputs['Color'])
links.new(emission.outputs[0], nodes.get('Material Output').inputs['Surface'])
baked = bpy.data.images.new('GoblinNativeSkin - Community UV bake', width=256, height=256, alpha=True)
target = nodes.new('ShaderNodeTexImage')
target.image = baked
nodes.active = target
# A UV-full quad preserves every native texel, including hidden body sections.
plane = mesh_object('Temporary UV bake surface', [(0,0,0),(1,0,0),(1,1,0),(0,1,0)], [[0,1,2,3]], [(0,0),(1,0),(1,1),(0,1)])
plane.data.materials.append(skin_mat)
active(plane)
scene.render.engine = 'CYCLES'
scene.cycles.samples = 1
scene.render.bake.margin = 0
bpy.ops.object.bake(type='EMIT')
skin_path = MEDIA/'textures/Body/Goblin/GoblinNativeSkin.png'
skin_path.parent.mkdir(parents=True, exist_ok=True)
baked.filepath_raw = str(skin_path)
baked.file_format = 'PNG'
baked.save()
bpy.data.objects.remove(plane, do_unlink=True)

community_skin = baked.copy()
community_skin.name = 'Goblin green skin - original Community Rig UV'
native_bake = mesh_object('Temporary Community-to-game UV transfer',
    [(x,z,y) for x,y,z in native.vertices], bake_faces, [(u,1-v) for u,v in native.uv])
uv_node = nodes.new('ShaderNodeUVMap')
uv_node.uv_map = body.data.uv_layers.active.name
links.new(uv_node.outputs['UV'],skin_node.inputs['Vector'])
body.data.materials.clear()
body.data.materials.append(skin_mat)
transfer_mat,transfer_target = material('Temporary bake destination',baked)
for link in list(transfer_mat.node_tree.links):
    if link.from_node==transfer_target:
        transfer_mat.node_tree.links.remove(link)
transfer_mat.node_tree.nodes.active=transfer_target
native_bake.data.materials.append(transfer_mat)
active(native_bake)
body.select_set(True)
scene.render.bake.use_clear = False
scene.render.bake.margin = 2
scene.render.bake.use_selected_to_active = True
scene.render.bake.cage_extrusion = 0.002
scene.render.bake.max_ray_distance = 0.004
bpy.ops.object.bake(type='EMIT')
baked.save()
bpy.data.objects.remove(native_bake,do_unlink=True)
scene.render.bake.use_selected_to_active = False

# EMIT baking writes opaque alpha. Preserve the native body's cut-outs: its
# transparent dress/pelvis atlas area must never become an opaque green panel.
alpha_mat,alpha_color = material('Native body cut-outs',baked)
an,al=alpha_mat.node_tree.nodes,alpha_mat.node_tree.links
native_alpha=an.new('ShaderNodeTexImage')
native_alpha.image=bpy.data.images.load(str(args.game/'media/textures/Body/MaleBody01.png'))
native_alpha.interpolation='Closest'
emit=an.new('ShaderNodeEmission')
al.new(alpha_color.outputs['Color'],emit.inputs['Color'])
transparent=an.new('ShaderNodeBsdfTransparent')
mix=an.new('ShaderNodeMixShader')
al.new(native_alpha.outputs['Alpha'],mix.inputs[0])
al.new(transparent.outputs[0],mix.inputs[1])
al.new(emit.outputs[0],mix.inputs[2])
al.new(mix.outputs[0],an.get('Material Output').inputs['Surface'])
alpha_plane=mesh_object('Temporary native alpha material bake',[(0,0,0),(1,0,0),(1,1,0),(0,1,0)],[[0,1,2,3]],[(0,0),(1,0),(1,1),(0,1)])
alpha_plane.data.materials.append(alpha_mat)
hidden={obj:obj.hide_render for obj in scene.objects}
for obj in scene.objects:
    obj.hide_render=obj!=alpha_plane
alpha_camera=bpy.data.objects.new('Temporary alpha camera',bpy.data.cameras.new('Temporary alpha camera'))
scene.collection.objects.link(alpha_camera)
alpha_camera.location=(0.5,0.5,1)
alpha_camera.data.type='ORTHO'
alpha_camera.data.ortho_scale=1
scene.camera=alpha_camera
scene.render.resolution_x=256
scene.render.resolution_y=256
scene.render.resolution_percentage=100
scene.render.film_transparent=True
scene.render.filter_size=0.01
scene.view_settings.view_transform='Standard'
scene.render.image_settings.file_format='PNG'
scene.render.image_settings.color_mode='RGBA'
scene.render.filepath=str(skin_path)
bpy.ops.render.render(write_still=True)
for obj,value in hidden.items():
    obj.hide_render=value
bpy.data.objects.remove(alpha_plane,do_unlink=True)
bpy.data.objects.remove(alpha_camera,do_unlink=True)
scene.render.film_transparent=False
scene.render.filter_size=1.5
baked.reload()
# Validate that every fully transparent native texel remains transparent.
source_alpha=list(native_alpha.image.pixels)[3::4]
result_alpha=list(baked.pixels)[3::4]
transparent_texels=sum(a==0 for a in source_alpha)
if transparent_texels==0 or any(b>0.01 for a,b in zip(source_alpha,result_alpha) if a==0):
    raise RuntimeError('Native skin alpha cut-outs were not preserved')

body_mat, tex = material('Goblin - native body and PZ uniform preview', community_skin)
output = tex.outputs['Color']
for name in ('Clothes/Shirt_Tshirt_Textures/Shirt_Priest.png', 'Clothes/Shoes_Socks_Textres/BikerBoots.png'):
    layer = body_mat.node_tree.nodes.new('ShaderNodeTexImage')
    layer.image = bpy.data.images.load(str(args.game/'media/textures'/name))
    layer.interpolation = 'Closest'
    mix = body_mat.node_tree.nodes.new('ShaderNodeMixRGB')
    body_mat.node_tree.links.new(layer.outputs['Alpha'], mix.inputs[0])
    body_mat.node_tree.links.new(output, mix.inputs[1])
    body_mat.node_tree.links.new(layer.outputs['Color'], mix.inputs[2])
    output = mix.outputs[0]
body_mat.node_tree.links.new(output, body_mat.node_tree.nodes.get('Principled BSDF').inputs['Base Color'])
body.data.materials.clear()
body.data.materials.append(body_mat)

# Hide just the stock face, mirroring the runtime clothing mask Head=0.
head_group = body.vertex_groups['Bip01_Head'].index
stock_head = {v.index for v in body.data.vertices if any(g.group==head_group and g.weight>=0.5 for g in v.groups)}
edit = bmesh.new()
edit.from_mesh(body.data)
edit.faces.ensure_lookup_table()
bmesh.ops.delete(edit, geom=[f for f in edit.faces if all(v.index in stock_head for v in f.verts)], context='FACES_ONLY')
edit.to_mesh(body.data)
edit.free()

head = mesh_object('Goblin head - native Bip01_Head', vertices, faces, uv)
atlas = bpy.data.images.load(str(ART/'textures/Material_1_basecolor.png'))
head_mat, _ = material('Goblin head - original matching atlas', atlas)
head.data.materials.append(head_mat)
active(head)
# UV seams belong to face corners, not disconnected geometry. Weld before
# simplification so the reducer cannot pull neighboring atlas islands apart.
edit=bmesh.new()
edit.from_mesh(head.data)
bmesh.ops.remove_doubles(edit,verts=list(edit.verts),dist=0.000001)
edit.to_mesh(head.data)
edit.free()
decimate = head.modifiers.new('Runtime head triangle budget', 'DECIMATE')
decimate.ratio = min(1.0, 1800/len(faces))
decimate.use_collapse_triangulate = True
bpy.ops.object.modifier_apply(modifier=decimate.name)
head.data.calc_loop_triangles()
if len(head.data.loop_triangles) > 2100:
    raise RuntimeError('Head triangle budget exceeded')

# Export head-only geometry in native coordinates, preserving PZ frame hierarchy
# and native inverse bind. Nothing from the control rig goes into the game.
candidate = copy.deepcopy(native)
candidate.vertices, candidate.faces, candidate.uv = [], [], []
candidate.normals, candidate.normal_faces = [], []
remap = {}
for tri in head.data.loop_triangles:
    face = []
    for vi,li in zip(reversed(tri.vertices), reversed(tri.loops)):
        u = tuple(head.data.uv_layers.active.data[li].uv)
        key = (vi,u)
        if key not in remap:
            p = head.data.vertices[vi].co
            remap[key] = len(candidate.vertices)
            candidate.vertices.append([p.x,p.z,p.y])
            candidate.uv.append([u[0],1-u[1]])
        face.append(remap[key])
    candidate.faces.append(face)
    normals=[]
    for vi in reversed(tri.vertices):
        normal=head.data.vertices[vi].normal
        normals.append(len(candidate.normals))
        candidate.normals.append([normal.x,normal.z,normal.y])
    candidate.normal_faces.append(normals)
candidate.skin = {'Bip01_Head':copy.deepcopy(native.skin['Bip01_Head'])}
candidate.skin['Bip01_Head']['weights'] = dict.fromkeys(range(len(candidate.vertices)),1.0)
head_path = MEDIA/'models_X/Skinned/Goblin/GoblinHead.x'
head_path.write_text(write_mesh(candidate), encoding='utf-8')
group = head.vertex_groups.new(name='Bip01_Head')
group.add(list(range(len(head.data.vertices))),1,'REPLACE')
head.modifiers.new('Community Rig human head', 'ARMATURE').object = rig

# Native trousers use the same native vertices/weights and their own matching UV.
trousers = read_mesh((args.game/'media/models_X/Skinned/Clothes/Bob_Trousers.x').read_text())
pants = mesh_object('PZ Trousers Black - reference clothing', [(x,z,y) for x,y,z in trousers.vertices],
    [list(reversed(f)) for f in trousers.faces], [(u,1-v) for u,v in trousers.uv])
pants_mat,_ = material('PZ black trousers', bpy.data.images.load(str(args.game/'media/textures/Clothes/Trousers_Mesh/TrousersMesh_Black.png')))
pants.data.materials.append(pants_mat)
for name,data in trousers.skin.items():
    group = pants.vertex_groups.new(name=name)
    for i,w in data['weights'].items():
        group.add([i],w,'REPLACE')
pants.modifiers.new('Community Rig human trousers', 'ARMATURE').object=rig

rig.show_in_front = True
active(rig)
scene.view_settings.view_transform = 'Standard'
scene.render.engine = 'CYCLES'
scene.cycles.samples = 24
scene.render.resolution_x = 850
scene.render.resolution_y = 1050
scene.render.resolution_percentage = 100
camera = bpy.data.objects.new('Goblin front camera', bpy.data.cameras.new('Goblin front camera'))
scene.collection.objects.link(camera)
camera.location=(0,-3,0.54)
camera.rotation_euler=(Vector((0,0,0.54))-camera.location).to_track_quat('-Z','Y').to_euler()
camera.data.type='ORTHO'
camera.data.ortho_scale=1.2
scene.camera=camera
for name,location,power in [('Key',(-1,-2,2),150),('Fill',(1,-1,1.5),65)]:
    data=bpy.data.lights.new(name,'AREA')
    data.energy=power
    data.size=2
    obj=bpy.data.objects.new(name,data)
    scene.collection.objects.link(obj)
    obj.location=location
    obj.rotation_euler=(Vector((0,0,0.5))-obj.location).to_track_quat('-Z','Y').to_euler()
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type=='VIEW_3D':
            area.spaces.active.shading.type='MATERIAL'
            area.spaces.active.region_3d.view_location=(0,0,0.52)
            area.spaces.active.region_3d.view_distance=1.7
            area.spaces.active.region_3d.view_rotation=Quaternion((1,0,0),1.5707963)
            area.spaces.active.region_3d.view_perspective='ORTHO'
info=bpy.data.texts.new('Goblin - asset credits and runtime architecture')
info.write('Authoring rig: Community Rig v4.0.1 by Paddlefruit.\n'
    'https://github.com/Paddlefruit/ProjectZomboid_CommunityRig\n'
    'Native human geometry, skeleton, skin and clothes: The Indie Stone, for Project Zomboid modding.\n'
    'Skin is authored on Community Rig male UVs; hand-UV differences are baked onto installed-game UVs.\n'
    'Runtime uses the GAME human body/clothing and only exports the custom head, with native Head inverse bind.\n'
    'Reference rig scripts are not needed by the game or executed automatically by this builder.\n'
    'Scene is in REST position for fitting. Use the community controls for authoring after explicitly registering them.\n')
bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=str(ART/'Goblin_Community_Final.blend'))
report={'community_rig':'Paddlefruit Community Rig v4.0.1',
    'community_rig_sha256':hashlib.sha256(args.community_rig.read_bytes()).hexdigest(),
    'body':'native PZ male body; not replaced globally',
    'body_uv_source':'Community Rig OBJ-MaleBody (0), TEX-DefaultMale',
    'community_native_uv_max_difference_before_bake':max(uv_errors),
    'community_native_vertex_max_error':max(position_errors),
    'native_triangles_surface_baked':len(bake_faces),
    'community_uv_conversion':'shader bake onto installed native UVs, including corrected hand corners',
    'head_triangles':len(candidate.faces),'head_vertices':len(candidate.vertices),
    'head_bones':['Bip01_Head'],'head_max_influences':1,
    'head_sha256':hashlib.sha256(head_path.read_bytes()).hexdigest(),
    'skin_sha256':hashlib.sha256(skin_path.read_bytes()).hexdigest(),
    'native_transparent_texels_preserved':transparent_texels,
    'skin_texture':'Body/Goblin/GoblinNativeSkin.png',
    'runtime_head':'x:Skinned/Goblin/GoblinHead','native_facing_axis':'-Z','native_up_axis':'+Y',
    'clothing':'Native Shirt_Priest, Trousers_Black, Shoes_BlackBoots and Hat_Beret ItemVisuals'}
(ART/'Goblin_Community_Final_report.json').write_text(json.dumps(report,indent=2)+'\n')
print('GOBLIN_COMMUNITY_BUILD',json.dumps(report))
if args.render:
    scene.render.filepath=str(QA/'community_final_front.png')
    bpy.ops.render.render(write_still=True)
