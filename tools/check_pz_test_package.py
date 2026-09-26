"""Read-only preflight: compare every installed test-package file to source.

Run for both direct and Workshop copies in each disposable client cache.
Matching package bytes establish test provenance, not gameplay acceptance.
"""
import argparse
import hashlib
from pathlib import Path


DEFAULT_SOURCE = Path(__file__).resolve().parents[1] / "mod/Contents/mods/GoblinSurvivor"


def fingerprint(root):
    root = Path(root)
    if not root.is_dir():
        raise ValueError(f"Package directory is missing: {root}")
    files = {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*") if path.is_file()
    }
    if not files:
        raise ValueError(f"Package directory is empty: {root}")
    return files


def differences(expected, actual):
    return {
        "missing": sorted(expected.keys() - actual.keys()),
        "unexpected": sorted(actual.keys() - expected.keys()),
        "changed": sorted(name for name in expected.keys() & actual.keys()
                          if expected[name] != actual[name]),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--package-dir", type=Path, action="append", required=True)
    args = parser.parse_args(argv)
    try:
        expected = fingerprint(args.source)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"{exc}\n")
    failed = False
    for root in args.package_dir:
        try:
            delta = differences(expected, fingerprint(root))
        except (OSError, ValueError) as exc:
            print(f"FAIL {root}: {exc}")
            failed = True
            continue
        if any(delta.values()):
            failed = True
            print(f"FAIL {root}")
            for kind, paths in delta.items():
                if paths:
                    print(f"  {kind} ({len(paths)}): {', '.join(paths[:10])}")
        else:
            print(f"MATCH {root}: {len(expected)} files, exact SHA-256 and file set")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
