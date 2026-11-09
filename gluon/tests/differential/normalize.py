#!/usr/bin/env python3
"""Normalization for differential parity (P-6).

- Paths: replace absolute build/source dirs with placeholders.
- Commands: replace compiler paths with basename, sort non-semantic args
  (-I, -D, -L, -isystem) while preserving semantic order for -o, inputs.
- Artifacts: for text, normalize paths; for binaries, compare symbols.
"""
import pathlib
import re
import sys


def normalize_path(text: str, replacements: list[tuple[str, str]]) -> str:
    for old, new in replacements:
        text = text.replace(old, new)
    return text


# tokens starting with these prefixes are order-insensitive
SORTABLE_PREFIXES = ("-I", "-D", "-L", "-isystem", "-isysroot")


def normalize_command(cmd: str, replacements: list[tuple[str, str]]) -> str:
    cmd = normalize_path(cmd, replacements)
    # split respecting quotes crudely (keep tokens as-is)
    parts = cmd.split()
    if not parts:
        return ""
    # replace compiler path with basename
    # first token may be '/usr/bin/cc' or 'cc' or 'python3'
    if parts[0].startswith("/"):
        parts[0] = pathlib.Path(parts[0]).name
    # collect sortable args and preserve others in place
    sortable = sorted([p for p in parts if p.startswith(SORTABLE_PREFIXES)])
    # remove sortable from sequence, insert sorted at first sortable position
    rest = [p for p in parts if not p.startswith(SORTABLE_PREFIXES)]
    # re-insert sorted block after first non-sortable? For simplicity, append sorted at end
    # of command before -o handling would be ideal, but for S2 we compare sets
    # of normalized commands sorted, so exact position does not matter if we
    # consistently move sortable to end.
    if sortable:
        # keep -o <out> at end if present
        if "-o" in rest:
            idx = rest.index("-o")
            head = rest[:idx]
            tail = rest[idx:]
            rest = head + sortable + tail
        else:
            rest = rest + sortable
    return " ".join(rest)


def extract_commands(build_ninja: pathlib.Path) -> list[str]:
    cmds: list[str] = []
    for line in build_ninja.read_text().splitlines():
        line = line.strip()
        if line.startswith("command = "):
            cmds.append(line[len("command = "):].strip())
        elif line.startswith("command="):
            cmds.append(line[len("command="):].strip())
    return cmds


def compare_command_sets(ref: list[str], cand: list[str], repl: list[tuple[str, str]]) -> tuple[bool, str]:
    ref_norm = sorted(normalize_command(c, repl) for c in ref)
    cand_norm = sorted(normalize_command(c, repl) for c in cand)
    if ref_norm == cand_norm:
        return True, ""
    diff = []
    diff.append(f"ref cmds ({len(ref_norm)}):")
    for c in ref_norm:
        diff.append(f"  {c}")
    diff.append(f"cand cmds ({len(cand_norm)}):")
    for c in cand_norm:
        diff.append(f"  {c}")
    return False, "\n".join(diff)


def selftest() -> int:
    repl = [("/tmp/ref/build", "$BUILD"), ("/tmp/cand/build", "$BUILD"), ("/tmp/src", "$SRC")]
    # path normalization
    assert normalize_path("/tmp/ref/build/a.o", repl) == "$BUILD/a.o"
    assert normalize_path("/tmp/cand/build/a.o", repl) == "$BUILD/a.o"
    # command normalization: compiler basename + sortable
    c1 = normalize_command("cc -D2 -D1 -c /tmp/src/a.c -o /tmp/ref/build/a.o", repl)
    c2 = normalize_command("/usr/bin/cc -D1 -D2 -c /tmp/src/a.c -o /tmp/cand/build/a.o", repl)
    assert c1 == c2, f"{c1!r} != {c2!r}"
    # command sets
    ok, _ = compare_command_sets(["cc -D1 -c a.c -o a.o"], ["cc -D1 -c a.c -o a.o"], [])
    assert ok
    ok, _ = compare_command_sets(["cc -D1 -c a.c -o a.o"], ["cc -D2 -c a.c -o a.o"], [])
    assert not ok
    print("normalize selftest ok")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    print("usage: normalize.py --selftest", file=sys.stderr)
    sys.exit(2)
