##! The XSH terminfo compiler: `/usr/bin/tic`, a port of ncurses 6.6's `tic -x`
##! that writes byte-identical compiled entries.  Recipes that compile
##! terminfo source at build time (the `terminfo` database) take it as a host
##! build dependency, like `m4` and `flex`.
## Package recipe export.
export const name = "tic"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The ncurses release whose compiler and capability table tic follows.
export const ver = "6.6"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps: List[Str] = []

## Package recipe export.
export let mkdeps_host = []

## `/usr/bin/tic` is an XSH script; it needs the `xsh` runner at runtime.
export const runtime_only_deps = ["xsh"]

## The compiler is in-tree XSH.  The ncurses tarball supplies only
## include/Caps and include/Caps-ncurses, which the build checks the
## compiler's embedded capability table against; no ncurses code is built.
export const upstream_sources = [
  {
    source: p"files/tic.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"https://invisible-island.net/archives/ncurses/ncurses-VERSION.tar.gz => ncurses",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/bin/tic", kind: "file"}]

error CapsTableError = Missing(block: Str) | Mismatch(block: Str, row: Str)

# The text of the raw-string constant `name` in tic.xsh.
proc embedded_block(script: Str, name: Str) [error] -> Result[Str] {
  let opening = f"const {name} = r\"\"\"\n"
  let start = script.find(opening)
  if start == null {
    return Err(CapsTableError.Missing(name))
  }

  let body = start + opening.byte_len()
  let end = script.find("\n\"\"\"", body)
  if end == null {
    return Err(CapsTableError.Missing(name))
  }

  script.byte_slice(body, end - body)
}

# `awk '!/^#/ && NF {print $1, $2, $3}' include/Caps`
pure standard_rows(caps: Str) -> Str {
  [
    line.fields()[0..3].join(" ")
    for line in caps.split("\n")
    if ! line.starts_with("#") and ! line.fields().is_empty()
  ].join("\n")
}

# `awk '$1 == "infoalias" || $1 == "userdef" {print $1, $2, $3}' include/Caps-ncurses`
pure ncurses_rows(caps: Str) -> Str {
  [
    line.fields()[0..3].join(" ")
    for line in caps.split("\n")
    if ! line.fields().is_empty() and (line.fields()[0] == "infoalias" or line.fields()[0] == "userdef")
  ].join("\n")
}

# The binary format's capability order is the order of include/Caps; a
# compiler whose table drifted from the pinned release would write entries
# that readers misinterpret, so a mismatch fails the build.
proc check_caps_table() {
  let script = p"tic.xsh".read_text()?
  let checks = [
    {block: "standard_caps_rows", expected: standard_rows(p"ncurses/include/Caps".read_text()?)},
    {block: "ncurses_caps_rows", expected: ncurses_rows(p"ncurses/include/Caps-ncurses".read_text()?)},
  ]

  for {block, expected} in checks {
    let embedded = embedded_block(script, block)?
    if embedded != expected {
      let want = expected.split("\n")
      let have = embedded.split("\n")
      let differing = [k for k in range(want.len()) if k >= have.len() or want[k] != have[k]]
      let row = if ! differing.is_empty() { want[differing[0]] } else { have[want.len()] }
      return Err(CapsTableError.Mismatch(block:, row:))
    }
  }
}

## Package recipe export.
export proc build(dest: Path) [fs, error] {
  check_caps_table()
  fs.install(p"tic.xsh", fp"{dest}/usr/bin/tic", 0o755, parents: true, overwrite: true)
}
