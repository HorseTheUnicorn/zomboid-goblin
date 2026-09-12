"""Read the community body's native UV/material data without executing rig code."""
from pathlib import Path
import bpy

source = Path('C:/Users/tomgr/Downloads/Goblin-CommunityRig-v4.0.1/PZ_HumanRigV4.blend')
bpy.ops.wm.open_mainfile(filepath=str(source), use_scripts=False)
body = bpy.data.objects['OBJ-MaleBody (0)']
print('BODY', body.matrix_world, len(body.data.vertices), len(body.data.polygons))
print('UVS', [(uv.name, len(uv.data)) for uv in body.data.uv_layers])
print('IMAGES', [(im.name, tuple(im.size), im.filepath, im.packed_file is not None) for im in bpy.data.images])
for mat in body.data.materials:
    print('MATERIAL', mat.name)
    for node in mat.node_tree.nodes:
        print('NODE', node.name, node.type, getattr(getattr(node, 'image', None), 'name', ''),
              [(i.name, str(i.default_value)) for i in node.inputs if hasattr(i, 'default_value')])
    print('LINKS', [(l.from_node.name, l.from_socket.name, l.to_node.name, l.to_socket.name) for l in mat.node_tree.links])
