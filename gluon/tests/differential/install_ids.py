#!/usr/bin/env python3
"""Print install names of shared libraries in an installed tree.

Binaries are masked as "binary" by install_snapshot.py, so install names
(SONAME / LC_ID_DYLIB) and Darwin compatibility/current versions are compared
separately here.
"""
import os
import subprocess
import sys

MACHO = {
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}


def macho_id(path: str):
    try:
        result = subprocess.run(
            ["otool", "-l", path], capture_output=True, text=True, check=False
        )
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    lines = result.stdout.splitlines()
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_ID_DYLIB":
            continue
        name = ""
        compatibility = ""
        current = ""
        for entry in lines[index + 1 :]:
            stripped = entry.strip()
            if stripped.startswith("cmd ") or stripped.startswith("Load command"):
                break
            if stripped.startswith("name "):
                name = stripped[len("name ") :].split(" (offset")[0].strip()
            elif stripped.startswith("compatibility version "):
                compatibility = stripped.split()[2]
            elif stripped.startswith("current version "):
                current = stripped.split()[2]
        return f"{name} {compatibility} {current}".strip()
    return None


def elf_soname(path: str):
    try:
        result = subprocess.run(
            ["readelf", "-d", path], capture_output=True, text=True, check=False
        )
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if "(SONAME)" in line and "[" in line:
            return line.split("[", 1)[1].split("]", 1)[0]
    return None


def install_id(path: str):
    try:
        with open(path, "rb") as handle:
            head = handle.read(8)
    except OSError:
        return None
    if head.startswith(b"\x7fELF"):
        return elf_soname(path)
    if head[:4] in MACHO:
        return macho_id(path)
    return None


def snapshot(root: str) -> None:
    rows = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            identifier = install_id(path)
            if identifier:
                rows.append(f"{os.path.relpath(path, root)}\t{identifier}")
    for row in sorted(rows):
        print(row)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: install_ids.py <root>", file=sys.stderr)
        sys.exit(2)
    snapshot(sys.argv[1])
