"""Blender background diagnostic: compare source UVs with a flipped V channel.

Run with Blender --background --python tools/preview_goblin.py -- source.blend output.png.
This renders the mesh; it does not edit the texture or save over the source.
"""
import json
from pathlib import Path
import sys
import bpy
from mathutils import Vector

source, output = sys.argv[sys.argv.index("--") + 1:]
if Path(source).suffix == '.fbx':
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=str(Path(source).resolve()))
else:
    bpy.ops.wm.open_mainfile(filepath=str(Path(source).resolve()))
mesh = bpy.data.objects["Goblin_Mesh"]
print("GOBLIN_MODEL", json.dumps({"materials": [m.name for m in mesh.data.materials],
      "uvs": [u.name for u in mesh.data.uv_layers],
      "images": [{"name": i.name, "path": i.filepath, "packed": bool(i.packed_file)} for i in bpy.data.images]}))
for obj in bpy.data.objects:
    obj.hide_render = obj.type == "MESH"
# Normalize only this disposable preview, including FBX armature transforms.
evaluated = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
preview_data = bpy.data.meshes.new_from_object(evaluated)
preview_data.transform(mesh.matrix_world)
mesh = bpy.data.objects.new("PreviewMesh", preview_data)
bpy.context.collection.objects.link(mesh)
low = Vector(tuple(min(v.co[i] for v in preview_data.vertices) for i in range(3)))
high = Vector(tuple(max(v.co[i] for v in preview_data.vertices) for i in range(3)))
center = Vector(((low.x + high.x) / 2, (low.y + high.y) / 2, low.z))
height = high.z - low.z
print("PREVIEW_NATIVE_BOUNDS", tuple(low), tuple(high))
for vertex in preview_data.vertices:
    vertex.co = (vertex.co - center) * (0.98 / height)
mesh.hide_render = False
texture = Path(__file__).resolve().parents[1] / "art/goblin/textures/Material_1_basecolor.png"
material = bpy.data.materials.new("UV inspection")
material.use_nodes = True
nodes = material.node_tree.nodes
nodes.clear()
image = nodes.new("ShaderNodeTexImage")
image.image = bpy.data.images.load(str(texture), check_existing=True)
emission = nodes.new("ShaderNodeEmission")
out = nodes.new("ShaderNodeOutputMaterial")
material.node_tree.links.new(image.outputs["Color"], emission.inputs["Color"])
material.node_tree.links.new(emission.outputs[0], out.inputs[0])
mesh.data.materials.clear()
mesh.data.materials.append(material)
mesh.location.x -= 0.27
other = mesh.copy()
other.data = mesh.data.copy()
bpy.context.collection.objects.link(other)
other.location.x += 0.54
for uv in other.data.uv_layers.active.data:
    uv.uv.y = 1.0 - uv.uv.y
camera_data = bpy.data.cameras.new("InspectionCamera")
camera = bpy.data.objects.new("InspectionCamera", camera_data)
bpy.context.collection.objects.link(camera)
camera.location = (0, -3, 0.65)
camera.rotation_euler = (Vector((0,0,0.5))-camera.location).to_track_quat('-Z','Y').to_euler()
camera_data.type = 'ORTHO'
camera_data.ortho_scale = 1.2
scene = bpy.context.scene
scene.camera = camera
scene.render.engine = 'CYCLES'
scene.cycles.samples = 8
scene.render.resolution_x = 900
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
if scene.world is None:
    scene.world = bpy.data.worlds.new("InspectionWorld")
scene.world.color = (0.12,0.12,0.12)
scene.view_settings.view_transform = 'Standard'
Path(output).parent.mkdir(parents=True,exist_ok=True)
scene.render.filepath = str(Path(output).resolve())
bpy.ops.render.render(write_still=True)
