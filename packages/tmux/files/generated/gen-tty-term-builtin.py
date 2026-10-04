#!/usr/bin/env python3
"""Generate tty-term-builtin.h: tmux's built-in terminfo entries.

Laputa ships no ncurses, so tmux cannot read a terminfo database for the
outer terminal. This compiles the entries Laputa users meet from ncurses'
terminfo.src into C tables in tmux's own "name=value" capability format
(the format tty_term_read_list produced from tigetstr), keeping only the
capabilities tmux's tty_term_codes table knows.

Regenerate on the host when ncurses or the tmux release changes:

    curl -fsSLO https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz
    echo '355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11  ncurses-6.6.tar.gz' | sha256sum -c
    tar xzf ncurses-6.6.tar.gz ncurses-6.6/misc/terminfo.src
    tar xzf tmux-3.7c.tar.gz tmux-3.7c/tty-term.c
    python3 gen-tty-term-builtin.py ncurses-6.6/misc/terminfo.src \\
        tmux-3.7c/tty-term.c > tty-term-builtin.h
"""

import re
import sys

# The outer terminals tmux must start in on Laputa: its own inner terminal
# (nested tmux), screen, foot (the profile's terminal), xterm and its
# derivatives, and the Linux console or a serial line.
TERMINALS = [
    "tmux-256color",
    "tmux",
    "screen-256color",
    "screen",
    "foot",
    "foot-direct",
    "xterm-256color",
    "xterm",
    "xterm-direct",
    "alacritty",
    "linux",
    "vt220",
    "vt100",
]

CANCEL = object()


def read_entries(path):
    """Map every name of every entry to its raw field list, in order."""
    entries = {}
    lines = []
    for line in open(path, encoding="latin-1"):
        line = line.rstrip("\n")
        if line.startswith("#") or not line.strip():
            continue
        if line[0] in " \t":
            lines[-1] += line.strip()
        else:
            lines.append(line)
    for line in lines:
        fields = split_fields(line)
        names = fields[0].split("|")
        for name in names[:-1] if len(names) > 1 else names:
            entries[name] = fields[1:]
    return entries


def split_fields(line):
    """Split on unescaped commas; terminfo.src escapes a literal comma as \\,."""
    fields, cur, i = [], "", 0
    while i < len(line):
        c = line[i]
        if c == "\\" and i + 1 < len(line):
            cur += line[i : i + 2]
            i += 2
            continue
        if c == ",":
            fields.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        fields.append(cur.strip())
    return [f for f in fields if f]


def resolve(entries, name, seen=()):
    """Capabilities of an entry after use= expansion: the first definition of
    a capability wins, and name@ cancels it for every later use=."""
    if name in seen:
        raise SystemExit(f"use= loop at {name}")
    caps = {}
    for field in entries[name]:
        if field.startswith("use="):
            for key, value in resolve(entries, field[4:], seen + (name,)).items():
                caps.setdefault(key, value)
        elif field.endswith("@"):
            caps.setdefault(field[:-1], CANCEL)
        elif "=" in field:
            key, value = field.split("=", 1)
            caps.setdefault(key, ("s", value))
        elif "#" in field:
            key, value = field.split("#", 1)
            caps.setdefault(key, ("n", str(int(value, 0))))
        else:
            caps.setdefault(field, ("b", "1"))
    return caps


def decode(value):
    """terminfo.src string escapes to the bytes tigetstr returns."""
    out, i = bytearray(), 0
    while i < len(value):
        c = value[i]
        if c == "\\" and i + 1 < len(value):
            n = value[i + 1]
            i += 2
            simple = {"E": 27, "e": 27, "n": 10, "l": 10, "r": 13, "t": 9,
                      "b": 8, "f": 12, "s": 32, "^": 94, "\\": 92, ",": 44,
                      ":": 58, "a": 7}
            if n in simple:
                out.append(simple[n])
            elif n in "01234567":
                digits = n
                while i < len(value) and len(digits) < 3 and value[i] in "01234567":
                    digits += value[i]
                    i += 1
                code = int(digits, 8)
                out.append(0o200 if code == 0 else code)
            else:
                out.append(ord(n))
        elif c == "^" and i + 1 < len(value):
            n = value[i + 1]
            i += 2
            out.append(127 if n == "?" else ord(n.upper()) & 0x1F)
        else:
            out.extend(c.encode("latin-1"))
            i += 1
    return bytes(out)


def c_literal(data):
    out = ""
    for b in data:
        ch = chr(b)
        if ch == "\\":
            out += "\\\\"
        elif ch == '"':
            out += '\\"'
        elif ch == "?":
            # Avoid C trigraphs.
            out += "\\?"
        elif 32 <= b < 127:
            out += ch
        else:
            out += f"\\{b:03o}"
    return out


def tmux_codes(path):
    return set(re.findall(r'\{\s*TTYCODE_\w+,\s*"(\w+)"\s*\}', open(path).read()))


def main():
    entries = read_entries(sys.argv[1])
    known = tmux_codes(sys.argv[2])
    print("/* Generated by gen-tty-term-builtin.py from ncurses 6.6 terminfo.src. */")
    print("/* Do not edit: see that script for the regeneration command. */")
    print()
    table = []
    for term in TERMINALS:
        ident = "tty_term_builtin_" + re.sub(r"[^a-z0-9]", "_", term)
        caps = resolve(entries, term)
        print(f"static const char *{ident}[] = {{")
        for key in sorted(caps):
            value = caps[key]
            if value is CANCEL or key not in known:
                continue
            kind, text = value
            data = decode(text) if kind == "s" else text.encode()
            print(f'\t"{key}={c_literal(data)}",')
        print("\tNULL")
        print("};")
        print()
        table.append((term, ident))
    print("static const struct {")
    print("\tconst char\t *name;")
    print("\tconst char\t**caps;")
    print("} tty_term_builtins[] = {")
    for term, ident in table:
        print(f'\t{{ "{term}", {ident} }},')
    print("};")


main()
