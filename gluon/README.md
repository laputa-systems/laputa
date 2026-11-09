# gluon

gluon is a Meson-compatible build system and a Ninja-compatible executor,
written in Rust. One workspace builds three binaries:

- `meson` — Meson front end (graph generation + `build.ninja` output)
- `ninja` — Ninja executor (scheduler, depfiles, dyndep, `.ninja_log`)
- `gluon-build` — integrated binary dispatching to either front end

Parity target: Meson 1.12.1 and Ninja 1.13.2. Exact pins live in
`tests/upstream/PINS`. Behavioral parity (not byte-identical text) is the
test contract — see [docs/testing.md](docs/testing.md).

## Get it

Published as GitHub prereleases: tags `release-<commit-sha>`, with
`gluon-aarch64-apple-darwin.zip` and `gluon-x86_64-unknown-linux-musl.zip`
plus `SHA256SUMS`. Verify with:

```sh
tag=$(gh release list --repo joshuarli/gluon --limit 1 --json tagName -q '.[0].tagName')
gh release download "$tag" --repo joshuarli/gluon --pattern 'gluon-aarch64-apple-darwin.zip'
gh release download "$tag" --repo joshuarli/gluon --pattern 'SHA256SUMS'
grep -F 'gluon-aarch64-apple-darwin.zip' SHA256SUMS | shasum -a 256 -c -
```

Consumer installers: from `~/usr`, run `sh sync tools gluon`; from
`~/d/view`, run `make toolchain`. Building from source is `cargo build --profile dist --locked`.

## Run

```sh
./target/dist/meson setup builddir srcdir
./target/dist/ninja -C builddir
./target/dist/gluon-build meson setup builddir srcdir
./target/dist/gluon-build --version
```

The `dist` profile is the release profile used by CI and releases
(fat LTO, one codegen unit, stripped).

## License

`crates/meson` is MIT or Apache-2.0 (Oxidized Meson MIT; Meson Apache-2.0 —
see its `NOTICE` and license texts). `crates/ninja` is Apache-2.0
(Oxidized Ninja Apache-2.0; Ninja Apache-2.0 — see its `NOTICE`).
Muon was used as a behavioral specification only; no GPL code is included.
