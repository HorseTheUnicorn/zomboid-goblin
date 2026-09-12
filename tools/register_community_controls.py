"""Register the inspected external rig UI in this Blender process only."""
import hashlib
from pathlib import Path
import runpy

script=Path('C:/Users/tomgr/Downloads/Goblin-CommunityRig-v4.0.1/PY-PZ_HumanRig.py')
if hashlib.sha256(script.read_bytes()).hexdigest()!='037a31bf278b111414856199e5596e1626d92d29abf52ce98e884f08d7197963':
    raise RuntimeError('Community rig script changed; inspect it before running')
runpy.run_path(str(script),run_name='__main__')
