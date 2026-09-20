import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

from tools.export_native_map import export


class NativeMapExportTests(unittest.TestCase):
    def make_source(self, root, *, bad_name=False, missing=False, offset=False):
        source = root / "pyramid.zip"
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + struct.pack(">II", 256, 256)
        with zipfile.ZipFile(source, "w") as archive:
            archive.writestr("pyramid.txt", f"VERSION=1\nbounds={1 if offset else 0} 0 256 256\nimageSize=256 256\n")
            for level in range(4 if missing else 5):
                archive.writestr(f"{level}/tile0x0.png", png)
            if bad_name:
                archive.writestr("../outside.txt", "unsafe")
        return source, png

    def test_preserves_native_pixels_and_coordinate_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, png = self.make_source(root)
            result = export(source, root / "output", "42.20.4")
            self.assertEqual(result["tile_count"], 5)
            self.assertEqual(result["world"]["x_max"], 256)
            self.assertEqual((root / "output/0/tile0x0.png").read_bytes(), png)
            self.assertEqual(json.loads((root / "output/map-manifest.json").read_text())["kind"], "native-pyramid")
            with self.assertRaises(ValueError):
                export(source, root / "output", "42.20.4")

    def test_rejects_unsafe_paths_incomplete_levels_and_shifted_origins(self):
        for options in ({"bad_name": True}, {"missing": True}, {"offset": True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, _ = self.make_source(root, **options)
                with self.assertRaises(ValueError):
                    export(source, root / "output", "42.20.4")
                self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
