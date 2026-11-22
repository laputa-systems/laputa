# zlib-rs qualification

Census gate for the `zlib` row in [Native census](../../docs/NATIVE-CENSUS.md#zlib-gate-evidence-zlib-rs):
interface parity and a differential corpus, with the shipped C zlib as oracle
and the `zlib-rs` package as candidate. Nothing here installs the candidate or
changes `packages/zlib`.

```bash
# from the checkout root, with host XSH tools (see docs/DEVELOPMENT.md)
xsh qualification/zlib-rs/run.xsh -- x86_64
```

`run.xsh` builds `zlib`, `zlib-rs` and `llvm-toolchain` into the artifact store,
composes them into `.out/zlib-rs-gate/ARCH/root`, and runs `check.xsh` in the
offline package-tools container. It exits 0 only when `check.xsh` does.
`check.xsh ROOT` can also run directly wherever `ROOT` holds both libraries
(`usr/lib/libz.so.1` and `usr/lib/zlib-rs/libz.so.1`) and the root's `cc` runs.

- `check.xsh` compares SONAME, `DT_NEEDED`, `RUNPATH` and the versioned
  exported dynamic symbols, then the `z_stream` and `gz_header` layouts and
  constants (`abi.c`, compiled against both `zlib.h` files), then runs the
  differential driver. A symbol difference passes only if it is on the
  justified list in `check.xsh`.
- `differential.c` loads both libraries into one process and runs every case
  through each. It exits 1 on any unexplained difference.
- A `KNOWN DIVERGENCE` line is a behavior where the candidate is known to
  differ from the oracle; each is matched against a narrow pattern, so a
  different outcome fails instead of being absorbed. Five are recorded, and
  the exit status does not say whether they are acceptable.
