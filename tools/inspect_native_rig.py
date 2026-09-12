"""Read-only Blender diagnostics for native and converted Goblin bind spaces."""
import json
from pathlib import Path
import sys
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).parent))
from pz_x_mesh import read_mesh

root = Path(__file__).resolve().parents[1]
game = Path(r"C:/Program Files (x86)/Steam/steamapps/common/ProjectZomboid")
native = read_mesh((game/'media/models_X/Skinned/MaleBody.x').read_text())
def bounds(vertices):
    if not vertices: return None
    return [[min(v[i] for v in vertices) for i in range(3)], [max(v[i] for v in vertices) for i in range(3)]]
print('NATIVE', json.dumps({'vertices':len(native.vertices),'triangles':sum(len(f)-2 for f in native.faces),
    'bounds':bounds(native.vertices),'bones':list(native.skin),
    'max_weights':max(sum(i in b['weights'] for b in native.skin.values()) for i in range(len(native.vertices)))}))
for name in ('Bip01_Head','Bip01_Neck','Bip01_L_Hand','Bip01_R_Hand'):
    b=native.skin[name]
    matrix=Matrix([b['matrix'][i:i+4] for i in range(0,16,4)]).transposed().inverted()
    points=[native.vertices[i] for i,w in b['weights'].items() if w>=0.5]
    print('NATIVE_BIND',name, 'origin',tuple(matrix.translation),'matrix',list(map(list,matrix)),'bounds',bounds(points))
bpy.ops.wm.open_mainfile(filepath=str(root/'art/goblin/Goblin_PZ_MysteryRig.blend'))
mesh=bpy.data.objects['Goblin_Mesh']
print('SOURCE_WORLD',list(map(list,mesh.matrix_world)))
for armature in [o for o in bpy.data.objects if o.type=='ARMATURE']:
    print('ARMATURE',armature.name,list(map(list,armature.matrix_world)))
    for name in ('Bip01_Head','Bip01_L_Hand','Bip01_R_Hand','Bip01_L_UpperArm'):
        if name in armature.data.bones:
            print('SOURCE_BIND',name,list(map(list,armature.matrix_world@armature.data.bones[name].matrix_local)))
groups={g.index:g.name for g in mesh.vertex_groups}
for name in ('Bip01_Head','Bip01_Neck'):
    points=[mesh.matrix_world@v.co for v in mesh.data.vertices if any(groups[g.group]==name and g.weight>0.5 for g in v.groups)]
    print('SOURCE_HEAD',name,len(points),bounds(points))
