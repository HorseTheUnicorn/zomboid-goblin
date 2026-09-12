"""Validate the current Community Rig build, without restaging the obsolete body FBX.

Rebuild with Blender and tools/build_goblin_community.py when hashes differ.
"""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "mod/Contents/mods/GoblinSurvivor/common/media"


def main():
    report = json.loads((ROOT / "art/goblin/Goblin_Community_Final_report.json").read_text())
    for key, relative in (
        ("head_sha256", "models_X/Skinned/Goblin/GoblinHead.x"),
        ("skin_sha256", "textures/Body/Goblin/GoblinNativeSkin.png"),
    ):
        actual = hashlib.sha256((MEDIA / relative).read_bytes()).hexdigest()
        if actual != report[key]:
            raise SystemExit(f"Build report mismatch: {relative}")
        print(f"Verified {relative}: {actual}")


if __name__ == "__main__":
    main()
