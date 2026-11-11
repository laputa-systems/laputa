#!/usr/bin/env python3
"""Print a stable snapshot of an installed tree.

Linked binaries are reduced to a marker; their symbols are compared by the
build gate. Everything else is compared by content hash.
"""
import hashlib
import os
import stat
import sys

MACHO = {
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}


def is_binary(path: str) -> bool:
    try:
        with open(path, "rb") as handle:
            head = handle.read(8)
    except OSError:
        return False
    return (
        head.startswith(b"\x7fELF")
        or head.startswith(b"!<arch>\n")
        or head[:4] in MACHO
    )


def digest(path: str) -> str:
    if is_binary(path):
        return "binary"
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def snapshot(root: str) -> None:
    rows = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(dirnames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            mode = stat.S_IMODE(os.lstat(path).st_mode)
            rows.append(f"d\t{mode:o}\t{os.path.relpath(path, root)}")
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            relative = os.path.relpath(path, root)
            if os.path.islink(path):
                rows.append(f"l\t-\t{relative}\t{os.readlink(path)}")
            else:
                mode = stat.S_IMODE(os.lstat(path).st_mode)
                rows.append(f"f\t{mode:o}\t{relative}\t{digest(path)}")
    for row in sorted(rows):
        print(row)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: install_snapshot.py <root>", file=sys.stderr)
        sys.exit(2)
    snapshot(sys.argv[1])
