"""Export PZ's own map image pyramid unchanged; never read or modify a save."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import zipfile

TILE = re.compile(r"([0-4])/tile(\d+)x(\d+)\.png")


def export(source: Path, output: Path, build: str) -> dict:
    if output.exists():
        raise ValueError("Use a new output directory; existing map assets are preserved")
    with zipfile.ZipFile(source) as archive:
        metadata = dict(line.split("=", 1) for line in archive.read("pyramid.txt").decode().splitlines() if "=" in line)
        bounds = tuple(map(int, metadata["bounds"].split()))
        size = tuple(map(int, metadata["imageSize"].split()))
        if metadata.get("VERSION") != "1" or bounds[:2] != (0, 0) or size != bounds[2:]:
            raise ValueError("Unsupported pyramid coordinate mapping")
        if len(size) != 2 or not all(0 < n <= 65536 for n in size):
            raise ValueError("Invalid map dimensions")
        tiles = {}
        for member in archive.infolist():
            if member.is_dir() or member.filename == "pyramid.txt":
                continue
            match = TILE.fullmatch(member.filename)
            if not match or member.file_size > 1024 * 1024:
                raise ValueError("Unexpected pyramid member")
            level, x, y = map(int, match.groups())
            span = 256 * 2 ** level
            if x >= math.ceil(size[0] / span) or y >= math.ceil(size[1] / span):
                raise ValueError("Tile outside pyramid bounds")
            if (level, x, y) in tiles:
                raise ValueError("Duplicate pyramid tile")
            tiles[level, x, y] = member
        for level in range(5):
            expected = math.ceil(size[0] / (256 * 2 ** level)) * math.ceil(size[1] / (256 * 2 ** level))
            if sum(key[0] == level for key in tiles) != expected:
                raise ValueError(f"Incomplete pyramid level {level}")
        # Validate completely before creating the output directory.
        for member in tiles.values():
            data = archive.read(member)
            if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != (256, 256):
                raise ValueError("Expected unchanged 256-pixel PNG map tiles")
        output.mkdir(parents=True)
        for member in tiles.values():
            destination = output / member.filename
            destination.parent.mkdir(exist_ok=True)
            destination.write_bytes(archive.read(member))
    manifest = {
        "map_id": f"knox-country-native-{build}", "title": "Knox Country · native map",
        "build": build, "source": "Project Zomboid native map imagery from .03",
        "projection": "pz-world-tiles", "kind": "native-pyramid", "tile_size": 256,
        "min_level": 0, "max_level": 4, "map_directories": ["Muldraugh, KY"],
        "tiles": {"x_min": 0, "x_max": math.ceil(size[0] / 256) - 1,
                  "y_min": 0, "y_max": math.ceil(size[1] / 256) - 1},
        "world": {"x_min": 0, "y_min": 0, "x_max": size[0], "y_max": size[1], "units": "game tiles"},
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "tile_count": len(tiles),
        "attribution": "Map imagery © The Indie Stone. Unofficial server map.",
    }
    (output / "map-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    print(json.dumps(export(args.source, args.output, args.build), indent=2))
