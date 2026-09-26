import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from tools.check_pz_test_package import differences, fingerprint, main


class TestPackagePreflightTests(unittest.TestCase):
    def test_file_set_and_bytes_both_must_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source"
            target = Path(tmp) / "target"
            source.mkdir()
            target.mkdir()
            (source / "mod.info").write_bytes(b"current")
            (target / "mod.info").write_bytes(b"current")
            expected = fingerprint(source)
            self.assertFalse(any(differences(expected, fingerprint(target)).values()))
            (target / "mod.info").write_bytes(b"obsolete")
            (target / "stale.lua").write_bytes(b"old handler")
            (source / "new.lua").write_bytes(b"new handler")
            self.assertEqual(differences(fingerprint(source), fingerprint(target)), {
                "missing": ["new.lua"], "unexpected": ["stale.lua"],
                "changed": ["mod.info"],
            })
            before = (target / "mod.info").read_bytes()
            with contextlib.redirect_stdout(io.StringIO()):
                result = main(["--source", str(source), "--package-dir", str(source),
                               "--package-dir", str(target)])
            self.assertEqual(result, 1)
            self.assertEqual((target / "mod.info").read_bytes(), before)

    def test_missing_or_empty_package_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "empty"):
                fingerprint(tmp)
            with self.assertRaisesRegex(ValueError, "missing"):
                fingerprint(Path(tmp) / "absent")
