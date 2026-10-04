# TODO

Accepted Laputa and PM improvements not yet scheduled.

- **Package context through `ctx`.** About 874 PM error messages prefix
  `{pkg.name}` by hand and `ctx` is unused. Wrap each package's build and
  proof in `ctx f"building {pkg.name}" { ... }` in `pm/execute.xsh` and drop
  the prefixes; the context frame already appears in tracebacks.
- **`types.Target` instead of arch strings.** Recipes compare
  `target_arch()` with `"aarch64"` (~92 comparisons, ~129 calls), and every
  `else` branch silently means x86_64. Match exhaustively on the existing
  enum so a new target is a check error at each site.
- **`pm repo update-filetree PKG`**, like `update-checksums`: rewrite a
  recipe's filetree from its last built payload, reviewed as a diff, instead
  of one "built undeclared file" failure per rebuild (~1,300 hand-written
  entries).
- **Recipe defaults PM infers.** `name` is always the directory name (85 of
  85), `package_kind` is `"payload"` (83 of 85), `rel` is `"1"` (61 of 85),
  and sources repeat `architectures: ["all"]` with an `arch: "all"`
  checksum (310 entries). Default them, and lint a recipe that restates a
  default.
