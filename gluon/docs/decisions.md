# Decisions

Binding choices, newest first within each span; each entry names when it
reverses.

## 2026-11-09 (owner)

- **OD-1 Import & own.** Vendor the Oxidized Meson/Ninja sources into the
  workspace and evolve locally. Upstream repos are mirrors of a monorepo
  overwritten by upstream sync, so tracking them leaves no unattended path.
  Reverses only if upstream becomes authoritative again.
- **OD-2 Permissive only, with conservative notices.** Build on Oxidized.
  Neither upstream repo ships a LICENSE file; licenses are declared only in
  `Cargo.toml`. Meson carries the MIT text (as declared) and the Apache-2.0
  text with a NOTICE crediting the Meson project; Ninja carries the
  Apache-2.0 text with a NOTICE crediting Ninja. Muon behavior, commands, and
  outputs are specification only; copy no GPL code. Reverses only on an
  explicit owner rewrite of this boundary.
- **OD-3 Parity first, unification deferred.** `build.ninja` stays the
  interchange until direct typed-DAG lowering is qualified; the persistent
  graph snapshot lands only with the optimization slices. Reverses only if
  the differential harness shows the text boundary — not the implementations
  — is the blocker.
- **OD-4 Play gate.** The qualification gate is the Meson/Ninja subset
  against `~/d/play`: libplacebo 7.387.0 + Metal patch, SPIRV-Cross
  vulkan-sdk 1.4.363.0, and the player crates link against them with
  `CARGO_TARGET_DIR` under `.work/tmp`. Play is CMake-less (no `cmake` in
  `scripts/build-deps.sh`); Vulkan-Headers/Loader and shaderc come via
  bottles; SPIRV-Cross and libplacebo build via Meson. No CMake front end.
- **OD-5 Pushing.** Verified commits on `main` are pushed to `origin`
  (`git@github.com:joshuarli/gluon`) as they land. Never force-push. Red
  work never lands on `main`, so never reaches `origin`.
- **OD-6 Musl via Docker.** The static-musl artifact builds in a pinned
  Linux container (Docker, `--platform linux/amd64`, `tests/upstream/musl.sh`
  — or CI, per [.github/workflows/release.yml](../.github/workflows/release.yml)),
  never by installing a cross toolchain on the host.

## Prescribed

- **P-3 Pins.** Meson 1.12.1, Ninja 1.13.2, Muon 0.7.0. Muon is
  informational; its divergences are logged, never gating. The pin file is
  `tests/upstream/PINS` (reference versions, import SHAs, Docker image,
  libplacebo hash). Every reference update needs differential tests first.
- **P-4 Dependency gate.** New crates must show build-time, binary-size, and
  startup deltas and be the smallest viable option; no
  `-C target-cpu=native` in portable artifacts. The `meson` crate's
  serde/serde_json/toml/sha2 were replaced by mitsuhiko's `deser-json` /
  `deser-value` on owner direction (2026-11-09); the `sha2` entry was
  removed as unused. Measured delta at replacement: `meson` 1.51 MB →
  1.70 MB, `gluon-build` 1.75 MB → 1.94 MB (dist profile, macOS arm64),
  accepted on owner direction. `serde` 1.0.229 remains in `Cargo.lock`
  because `rust_decimal` depends on it. `deser-value` is the only JSON/XML context:
  introspection and `cmd_line.txt` round-trips run through it.
- **Releases.** The `dist` profile (`[profile.dist]` in `Cargo.toml`,
  inheriting `release` with one codegen unit and `strip`) is what CI and
  release workflows build (`.github/workflows/ci.yml`,
  `.github/workflows/release.yml`). Releases are workflow-dispatch only,
  tagged `release-<commit-sha>` with `--prerelease --verify-tag`, and ship
  `gluon-<target>.zip` archives plus `SHA256SUMS`.
