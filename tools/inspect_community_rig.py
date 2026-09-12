"""Inspect a downloaded .blend with auto-execution disabled; do not run its scripts."""
from pathlib import Path
import json
import bpy

source=Path('C:/Users/tomgr/Downloads/Goblin-CommunityRig-v4.0.1/PZ_HumanRigV4.blend')
bpy.ops.wm.open_mainfile(filepath=str(source),use_scripts=False)
for obj in bpy.data.objects:
    if obj.type in ('ARMATURE','MESH') and (obj.type=='ARMATURE' or len(obj.data.vertices)>200):
        print('OBJECT',obj.name,obj.type,'world',list(map(list,obj.matrix_world)),
              'modifiers',[(m.name,m.type,getattr(getattr(m,'object',None),'name',None)) for m in obj.modifiers])
        if obj.type=='ARMATURE':
            print('BONES',obj.name,[(b.name,b.use_deform) for b in obj.data.bones])
            print('PROPERTIES',obj.name,dict(obj.items()))
        else:
            print('MESH',obj.name,len(obj.data.vertices),'materials',[m.name if m else None for m in obj.data.materials],
                  'groups',[g.name for g in obj.vertex_groups][:50])
for text in bpy.data.texts:
    print('SCRIPT',text.name,len(text.as_string()),text.use_module)
    if text.name.endswith('.py'):
        (source.parent/text.name).write_text(text.as_string(),encoding='utf-8')
print('ACTIONS',[a.name for a in bpy.data.actions])
