"""Small reader/writer for the installed game's text DirectX skinned meshes.

Only a mesh block is replaced. Skeleton frames and native skin-offset matrices
are retained from the reference file, avoiding an FBX axis/armature conversion.
"""
from dataclasses import dataclass
import re

NUMBER = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")


def blocks(text, pattern):
    for match in re.finditer(pattern, text):
        start = text.index("{", match.start())
        depth, end = 1, start + 1
        while depth:
            depth += (text[end] == "{") - (text[end] == "}")
            end += 1
        yield match, text[start + 1:end - 1], end


class Numbers:
    def __init__(self, text):
        self.values = iter(float(v) for v in NUMBER.findall(text))

    def take(self, count):
        return [next(self.values) for _ in range(count)]

    def integer(self):
        return int(next(self.values))

    def vectors(self, dimension):
        return [self.take(dimension) for _ in range(self.integer())]

    def faces(self):
        return [[int(v) for v in self.take(self.integer())] for _ in range(self.integer())]


@dataclass
class Mesh:
    source: str
    start: int
    end: int
    vertices: list
    faces: list
    normals: list
    normal_faces: list
    uv: list
    skin: dict


def read_mesh(text):
    match, content, end = next(blocks(text, r"\bMesh\s+\w+\s*\{"))
    r = Numbers(content.split("MeshNormals", 1)[0])
    vertices, faces = r.vectors(3), r.faces()
    _, normals, _ = next(blocks(content, r"\bMeshNormals\s*\{"))
    r = Numbers(normals)
    normals, normal_faces = r.vectors(3), r.faces()
    _, uv, _ = next(blocks(content, r"\bMeshTextureCoords(?:\s+\w+)?\s*\{"))
    uv = Numbers(uv).vectors(2)
    skin = {}
    for _, weights, _ in blocks(content, r"\bSkinWeights\s*\{"):
        bone = re.search(r'"([^"]+)"', weights).group(1)
        r = Numbers(weights.split(";", 1)[1])
        count = r.integer()
        indices, values, matrix = r.take(count), r.take(count), r.take(16)
        skin[bone] = {"weights": dict(zip(map(int, indices), values)), "matrix": matrix}
    return Mesh(text, match.start(), end, vertices, faces, normals, normal_faces, uv, skin)


def number(value):
    # PZ's bundled X parser rejects exponent-only forms such as -1e-06.
    return format(float(value), ".9f")


def vectors(values):
    return str(len(values)) + ";\n" + ",\n".join(";".join(map(number, row)) + ";" for row in values) + ";\n"


def faces(values):
    return str(len(values)) + ";\n" + ",\n".join(str(len(row)) + ";" + ",".join(map(str, row)) + ";" for row in values) + ";\n"


def write_mesh(mesh):
    parts = ["Mesh GoblinNative {\n", vectors(mesh.vertices), faces(mesh.faces),
             "MeshNormals {\n", vectors(mesh.normals), faces(mesh.normal_faces), "}\n",
             "MeshTextureCoords c1 {\n", vectors(mesh.uv), "}\n",
             "MeshMaterialList {\n1;\n", str(len(mesh.faces)), ";\n",
             ",".join("0" for _ in mesh.faces), ";;\n",
             'Material GoblinSkin {1;1;1;1;;0;0;0;0;;0;0;0;;TextureFilename {"Goblin.png";}}\n}\n',
             "XSkinMeshHeader {4;12;", str(len(mesh.skin)), ";}\n"]
    for bone, data in mesh.skin.items():
        indices = sorted(data["weights"])
        parts += [f'SkinWeights {{\n"{bone}";\n{len(indices)};\n',
                  ",".join(map(str, indices)), ";\n",
                  ",".join(number(data["weights"][i]) for i in indices), ";\n",
                  ",".join(map(number, data["matrix"])), ";;\n}\n"]
    parts.append("}\n")
    return mesh.source[:mesh.start] + "".join(parts) + mesh.source[mesh.end:]
