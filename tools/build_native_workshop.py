"""Build a local Blender comparison from PZ's native mesh/animation import.

InspectPzMesh must first generate qa/native_{body,walk}_import.json. This is an
inspection candidate, NOT an automatic deployment to the game. The old asset is
never saved over. The native body's geometry and weights are not retargeted.
"""
import copy
from array import array
import json
from pathlib import Path
import sys
import bpy
import bmesh
from mathutils import Matrix, Quaternion, Vector

ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / 'art/goblin/qa'
sys.path.insert(0, str(Path(__file__).parent))
from pz_x_mesh import read_mesh, write_mesh

GAME = Path('C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid')
body_import = json.loads((QA/'native_body_import.json').read_text())
walk_import = json.loads((QA/'native_walk_import.json').read_text())
native = read_mesh((GAME/'media/models_X/Skinned/MaleBody.x').read_text())
# PZ mesh space is Y-up, facing -Z (nose/toes), NOT +Z (back/heels).
# Rotate to Blender Z-up, facing -Y. Determinant +1: no mirrored skin/winding.
C = Matrix(((-1,0,0,0),(0,0,1,0),(0,1,0,0),(0,0,0,1)))


def matrix(values):
    return Matrix([values[i:i+4] for i in range(0,16,4)])


def hierarchy(root):
    result = {}
    def visit(node, parent=None):
        result[node['name']] = {'parent':parent, 'local':matrix(node['matrix'])}
        for child in node['children']:
            visit(child, node['name'])
    visit(root)
    return result


nodes = hierarchy(walk_import['root'])
animation = walk_import['animations'][0]
channels = {c['name']:c for c in animation['channels']}


def sample(keys, tick, rotation=False):
    make = Quaternion if rotation else Vector
    if tick <= keys[0][0]: return make(keys[0][1:])
    for left,right in zip(keys,keys[1:]):
        if tick <= right[0]:
            amount = (tick-left[0])/(right[0]-left[0])
            a,b = make(left[1:]),make(right[1:])
            return a.slerp(b,amount) if rotation else a.lerp(b,amount)
    return make(keys[-1][1:])


def globals_at(tick):
    result={}
    for name,node in nodes.items():
        local=node['local']
        if name in channels:
            ch=channels[name]
            local=Matrix.LocRotScale(sample(ch['position'],tick),
                sample(ch['rotation'],tick,True),sample(ch['scale'],tick))
        parent=node['parent']
        result[name]=(result[parent]@local) if parent else local.copy()
    return result


def mesh_object(name, vertices, faces, uv, material):
    data=bpy.data.meshes.new(name)
    data.from_pydata(vertices,[],faces)
    data.update()
    layer=data.uv_layers.new(name='UVMap')
    for loop in data.loops:
        layer.data[loop.index].uv=uv[loop.vertex_index]
    for polygon in data.polygons: polygon.use_smooth=True
    data.materials.append(material)
    obj=bpy.data.objects.new(name,data)
    bpy.context.collection.objects.link(obj)
    return obj


def attach(obj, weights, rig):
    for name, values in weights.items():
        group=obj.vertex_groups.new(name=name)
        for i,weight in values.items(): group.add([int(i)],weight,'REPLACE')
    modifier=obj.modifiers.new('Native PZ weights','ARMATURE')
    modifier.object=rig


bpy.ops.wm.open_mainfile(filepath=str(ROOT/'art/goblin/Goblin_PZ_MysteryRig.blend'))
source=bpy.data.objects['Goblin_Mesh']
source.data.calc_loop_triangles()
group_names={g.index:g.name for g in source.vertex_groups}
head_ids={v.index for v in source.data.vertices if any(
    group_names[g.group]=='Bip01_Head' and g.weight>0.5 for g in v.groups)}
head_triangles=[tri for tri in source.data.loop_triangles if all(i in head_ids for i in tri.vertices)]
original_mesh=bpy.data.meshes.new_from_object(source.evaluated_get(bpy.context.evaluated_depsgraph_get()))
original_mesh.transform(source.matrix_world)
original_uv=source.data.uv_layers.active.data
head_vertices,head_uv,head_faces=[],[],[]
mapping={}
z_min=min(source.data.vertices[i].co.z for i in head_ids)
z_max=max(source.data.vertices[i].co.z for i in head_ids)
head_scale=0.8
for tri in head_triangles:
    face=[]
    for vertex_id,loop_id in zip(tri.vertices,tri.loops):
        uv=tuple(original_uv[loop_id].uv)
        key=(vertex_id,uv)
        if key not in mapping:
            p=source.matrix_world@source.data.vertices[vertex_id].co
            # Fit the whole beard/head/hat to the native neck, not to old bone axes.
            point=(-p.x*head_scale,0.99+(p.z-z_max)*head_scale,
                   p.y*head_scale+0.02)
            mapping[key]=len(head_vertices)
            head_vertices.append(point)
            head_uv.append(uv)
        face.append(mapping[key])
    head_faces.append(face)

# New scene, retaining the evaluated original only as a comparison reference.
for obj in list(bpy.data.objects): bpy.data.objects.remove(obj,do_unlink=True)
scene=bpy.context.scene
material=bpy.data.materials.new('Goblin original atlas')
material.use_nodes=True
texture=material.node_tree.nodes.new('ShaderNodeTexImage')
texture.image=bpy.data.images.load(str(ROOT/'art/goblin/textures/Material_1_basecolor.png'),check_existing=True)
bsdf=material.node_tree.nodes.get('Principled BSDF')
bsdf.inputs['Roughness'].default_value=0.85
material.node_tree.links.new(texture.outputs['Color'],bsdf.inputs['Base Color'])
original_mesh.materials.clear()
original_mesh.materials.append(material)
original=bpy.data.objects.new('01 Original Goblin - reference only',original_mesh)
bpy.context.collection.objects.link(original)
original.location.x=-1.1

# A single green texel is only a neutral skin preview, NOT the finished skin UV.
# Preserve the texture bitmap exactly; read a mid-green pixel from the source.
w,h=texture.image.size
pixels=array('f',[0.0])*(w*h*4)
texture.image.pixels.foreach_get(pixels)
green_uv=None
best_score=float('inf')
for y in range(20,h-20,7):
    for x in range(20,w-20,7):
        r,g,b,a=pixels[(y*w+x)*4:(y*w+x)*4+4]
        score=(r-0.44)**2+(g-0.49)**2+(b-0.18)**2
        if a>0.5 and g>0.15 and g>r*0.9 and b<g*0.65 and score<best_score:
            best_score=score
            green_uv=((x+0.5)/w,(y+0.5)/h)
if green_uv is None: raise RuntimeError('No green skin sample found')

rest={name:C@g for name,g in globals_at(0).items()}
for bone in body_import['meshes'][0]['bones']:
    rest[bone['name']]=C@matrix(bone['offset']).inverted()
armature=bpy.data.armatures.new('PZ native bind matrices')
rig=bpy.data.objects.new('02 Native PZ skeleton - Bob_Walk',armature)
bpy.context.collection.objects.link(rig)
bpy.context.view_layer.objects.active=rig
rig.select_set(True)
bpy.ops.object.mode_set(mode='EDIT')
for name,node in nodes.items():
    bone=armature.edit_bones.new(name)
    bone.length=0.035
    bone.matrix=rest[name]
    bone.use_deform=name in native.skin
    if node['parent']: bone.parent=armature.edit_bones[node['parent']]
bpy.ops.object.mode_set(mode='OBJECT')
rig.show_in_front=True
armature.display_type='STICK'
native_obj=mesh_object('02 Native body - exact game vertices and weights',
    [C@Vector(p) for p in native.vertices],native.faces,[green_uv]*len(native.vertices),material)
attach(native_obj,{name:data['weights'] for name,data in native.skin.items()},rig)
native_obj['note']='Unmodified native geometry and weights. Flat green is a preview, not finished clothing.'
head=mesh_object('03 Goblin head - rigid native Head binding',
    [C@Vector(p) for p in head_vertices],head_faces,head_uv,material)
attach(head,{'Bip01_Head':dict.fromkeys(range(len(head_vertices)),1.0)},rig)

scene.render.fps=30
scene.frame_start=1
scene.frame_end=21
for frame in range(1,22):
    glob=globals_at((frame-1)*160)
    pose_global={name:C@value for name,value in glob.items()}
    for name,node in nodes.items():
        parent=node['parent']
        basis=rest[name].inverted()@pose_global[name]
        if parent:
            basis=rest[name].inverted()@rest[parent]@pose_global[parent].inverted()@pose_global[name]
        bone=rig.pose.bones[name]
        bone.rotation_mode='QUATERNION'
        bone.matrix_basis=basis
        for field in ('location','rotation_quaternion','scale'):
            bone.keyframe_insert(field,frame=frame,group=name)
rig.animation_data.action.name='Native Bob_Walk - imported from installed PZ'

# Numerically compare Blender skinning with native G(t)*inverseBind at keyframes.
errors=[]
for frame in (1,6,11,16,21):
    scene.frame_set(frame)
    evaluated=native_obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
    glob=globals_at((frame-1)*160)
    expected=[Vector((0,0,0)) for _ in native.vertices]
    for bone in body_import['meshes'][0]['bones']:
        transform=C@glob[bone['name']]@matrix(bone['offset'])
        # Import can merge/split vertices; use the text mesh's original indices.
        for i,weight in native.skin[bone['name']]['weights'].items():
            expected[i]+=(transform@Vector(native.vertices[i]))*weight
    errors.append(max((expected[i]-v.co).length for i,v in enumerate(evaluated.data.vertices)))
if max(errors)>0.0001:
    for name in ('Bip01_Head','Bip01_L_UpperArm','Bip01_L_Hand'):
        print('BIND_CHECK',name,'desired',list(map(list,rest[name])),
              'actual',list(map(list,armature.bones[name].matrix_local)))
        print('POSE_CHECK',name,'desired',list(map(list,C@globals_at(3200)[name])),
              'actual',list(map(list,rig.pose.bones[name].matrix)))
    raise RuntimeError(f'Native skinning mismatch: {errors}')

# Remove the vanilla head surface only after checking the complete native mesh.
# Keeping it creates a second opaque face in front of the custom Goblin face.
native_head=set(i for i,w in native.skin['Bip01_Head']['weights'].items() if w>=0.5)
removed_faces={i for i,f in enumerate(native.faces) if all(v in native_head for v in f)}
edit=bmesh.new();edit.from_mesh(native_obj.data);edit.faces.ensure_lookup_table()
bmesh.ops.delete(edit,geom=[edit.faces[i] for i in removed_faces],context='FACES_ONLY')
edit.to_mesh(native_obj.data);edit.free()
native_obj.name='02 Native body - head surface replaced, original weights'
native_obj['note']='Native body and weights; only the original head faces are removed.'

# Store a non-deployed DirectX candidate with exact native skeleton/offsets.
candidate=copy.deepcopy(native)
candidate.faces=[f for i,f in enumerate(native.faces) if i not in removed_faces]
candidate.normal_faces=[f for i,f in enumerate(native.normal_faces) if i not in removed_faces]
start=len(candidate.vertices)
candidate.uv=[[green_uv[0],1-green_uv[1]] for _ in candidate.vertices]
candidate.vertices.extend([list(p) for p in head_vertices])
candidate.uv.extend([[u,1-v] for u,v in head_uv])
candidate.faces.extend([[i+start for i in face] for face in head_faces])
candidate.skin['Bip01_Head']['weights'].update({start+i:1.0 for i in range(len(head_vertices))})
for face in head_faces:
    points=[Vector(head_vertices[i]) for i in face]
    normal=(points[1]-points[0]).cross(points[2]-points[0]).normalized()
    index=len(candidate.normals)
    candidate.normals.append(list(normal))
    candidate.normal_faces.append([index]*3)
(QA/'Goblin_Native_Candidate.x').write_text(write_mesh(candidate),encoding='utf-8')

def label(text,x):
    data=bpy.data.curves.new(text,'FONT');data.body=text;data.align_x='CENTER';data.size=0.04
    obj=bpy.data.objects.new(text,data);bpy.context.collection.objects.link(obj)
    obj.location=(x,-0.05,1.11);obj.rotation_euler=(1.5707963,0,0)
label('ORIGINAL - reference',-1.1)
label('NATIVE PZ BODY + GOBLIN HEAD',0)
scene.frame_set(1)
scene.view_settings.view_transform='Standard'
camera_data=bpy.data.cameras.new('Front inspection')
camera=bpy.data.objects.new('Front inspection',camera_data)
bpy.context.collection.objects.link(camera)
camera.location=(-0.55,-3,0.55)
camera.rotation_euler=(Vector((-0.55,0,0.55))-camera.location).to_track_quat('-Z','Y').to_euler()
camera_data.type='ORTHO';camera_data.ortho_scale=2.0;scene.camera=camera
for name,location,power,size in [('Key',(-1,-2,2.5),120,3),('Fill',(1,1,1.5),80,2)]:
    light=bpy.data.lights.new(name,'AREA');light.energy=power;light.shape='DISK';light.size=size
    obj=bpy.data.objects.new(name,light);bpy.context.collection.objects.link(obj);obj.location=location
    obj.rotation_euler=(Vector((0,0,0.5))-obj.location).to_track_quat('-Z','Y').to_euler()
scene.render.engine='CYCLES';scene.cycles.samples=16
scene.render.resolution_x=1200;scene.render.resolution_y=850;scene.render.resolution_percentage=100
for obj in bpy.context.selected_objects: obj.select_set(False)
head.select_set(True);bpy.context.view_layer.objects.active=head
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type=='VIEW_3D':
            area.spaces.active.shading.type='MATERIAL'
            area.spaces.active.region_3d.view_location=(-0.5,0,0.55)
            area.spaces.active.region_3d.view_distance=2.5
            area.spaces.active.region_3d.view_rotation=Quaternion((1,0,0),1.5707963)
            area.spaces.active.region_3d.view_perspective='ORTHO'
info=bpy.data.texts.new('READ ME - Native rig workshop')
info.write('LEFT: original Goblin reference. RIGHT: exact native PZ body and weights with Goblin head.\n'
           'Space plays the installed game Bob_Walk cycle; frames 1-21.\n'
           'This is an inspection candidate only. Flat green body, clothing and head seam are unfinished.\n'
           'The original .blend/.fbx and running game have NOT been changed by this builder.\n'
           'The native walk deformation is numerically checked against imported skin matrices.\n')
bpy.ops.file.pack_all()
output=ROOT/'art/goblin/Goblin_Native_Comparison.blend'
bpy.ops.wm.save_as_mainfile(filepath=str(output))
report={'native_body_vertices':len(native.vertices),'native_body_triangles':len(native.faces),
        'replaced_native_head_triangles':len(removed_faces),
        'goblin_head_vertices':len(head_vertices),'goblin_head_triangles':len(head_faces),
        'native_animation':animation['name'],'blender_skinning_max_error':max(errors),
        'runtime_deployed':False,'body_skin_and_clothing':'preview only','head_scale':head_scale}
(QA/'native_workshop_report.json').write_text(json.dumps(report,indent=2)+'\n')
print('NATIVE_WORKSHOP',json.dumps(report))
if '--render' in sys.argv:
    scene.render.filepath=str(QA/'native_comparison_front.png')
    bpy.ops.render.render(write_still=True)
