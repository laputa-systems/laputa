# Local Laputa bootstrap campaign

Goal: build the whole Laputa world locally from a clean checkout of this
monorepo and `../xsh`, with:

- no dependence on `https://laputa.17166969.xyz`;
- sources served by a locally run mirror over plain unauthenticated HTTP;
- a locally built seed xsh;
- fast, cached rebuilds.

Laputa and XSH are developed together. Changes to xsh and xsht that make the
distribution simpler are in scope.

Phases 0–2 ran on Apple Silicon and stopped before `cmake` and `linux`. The
rest of the campaign runs on a fresh Linux amd64 host that has only git, make,
Docker, and the two checkouts (see "Linux amd64 host campaign").

Out of scope: GitHub CI, and building the mirror as a Laputa package (it is a
host tool).

## Done

**Phase 0: consolidation (2026-10-03).** The `packages`, `mirror` and `xinit`
repos were imported without history (D4) into one layout: `pm.xsh` and `pm/`,
`packages/<name>/`, `system/`, `xinit/`, `mirror/`, `seed/`, and
`tests/{pm,system,integration}/`. There is one `Makefile`, one
`xsht-config.ini` and one `AGENTS.md`, and containers mount the checkout at
`/src/laputa`. The `xinit` recipe builds from `repository/xinit/xinit.xsh`.
Stray scripts, the legacy x86_64 installer route and PM's `.env` reading were
deleted, and xinit was ported to current XSH. No sibling-path references
remain.

**Phase 1: four lanes (2026-10-03).**
- The mirror gained a `--local DIR` mode (filesystem storage, plain HTTP on
  127.0.0.1, no auth) and serves the source cache at `/sources/sha256/<hash>`.
- PM gained a content-addressed source cache. `pm sources fetch` (`make
  fetch`) is the only networked step, there is no default remote, and
  publishing to a loopback mirror needs no token. `sudo-rs` crates are
  vendored as sources.
- `make seed` builds static musl `xsh`/`xshi`/`xsht` and `core.tar.xz` from
  `XSH_ROOT` in XSH's `xsh-test` image, then the content-keyed package-tools
  image offline. The `xsh` package packages the seed (D6).
- Artifact keys follow D2: they exclude the executor, hash only build-dependency
  keys, and honor `BUILD_EPOCH`. A `runtime_only_deps` field keeps
  runtime-only edges out of build roots and keys.

**Phase 2: first local bootstrap on macOS (2026-10-03).**
- All 31 pre-cmake packages build offline from the local seed, publish to the
  local mirror, and compose a root whose ELF files load under musl and whose
  `xsh` runs.
- Measured cold, one step at a time: seed 336 s, build 123 s, publish 3.4 s. A
  rebuild with no change takes 8–11 s.
- The D2 proofs held. A new seed rebuilds only `xsh`. A PM edit rebuilds only
  `laputa-pm`. A `rel` bump rebuilds that package and its build dependents.
- The D8 follow-up made package identity content-addressed. Objects are named
  by artifact and proof key, the index row is the only mutable pointer, and a
  rebuild under the same `ver`-`rel` publishes cleanly.
- Fixes along the way:
  - `repo plan --all --without` computes the stop line from the real graph.
  - Bootstrap edges no longer select packages.
  - `make publish` builds the current plan before uploading it.

**Linux-host readiness (2026-10-03).**
- **Host tools without Rust.** `make host-xsh` builds the host tools in
  `xsh-test` with plain Docker: static `xsh`/`xshi`/`xsht` for the host arch
  in `.out/host/<arch>/`. It shares `.out/xsh-target` with the seed, and a
  test pins its cargo command to the seed's.
  - On Linux the Makefile uses these tools when `../xsh/target/release/xsh` is
    absent.
  - `make mirror` runs a static mirror built the same way. Its crates come
    from `make fetch`.
  - `ARCH` defaults to the host arch.
  - On Linux, `make clean` and `make root` remove root-owned,
    container-written state from a container.
- **x86_64 de-risked from macOS without amd64 Docker:**
  - The host-side `pm sources fetch --all --target x86_64-linux-musl` fetched
    58 sources (5 new) with 0 failures. Every URL source has an x86_64 pin.
  - A host-side offline `repo plan --all --target x86_64-linux-musl` plans
    all 69 recipes.
  - The Alpine base digest is a multi-arch index that includes `linux/amd64`.
  - A static audit fixed libnl3 and wpa_supplicant, whose compiler triple was
    always aarch64, and build-essential-native's proofs, which required an
    aarch64 root.
  - The audit also fixed the x86 kernel's `-march` flags (the `cc` wrapper's
    x86-64-v3 default was leaking in) and its shared, aarch64-derived
    `rq-offsets.h`.
- **aarch64 rerun, nothing regressed** (one step at a time, `linux/arm64`):

  | Step | Wall time | Result |
  |---|---|---|
  | `make clean` | 7.4 s | `.out/`, `target/` and Laputa images removed |
  | `make fetch` | 13.0 s | 58 sources cached, 0 fetched |
  | `make seed` | 493 s | cold release build in `xsh-test`, then package-tools |
  | `make mirror` | 1.1 s | listening |
  | `make build STOP=pre-cmake` | 107 s | 31 built and proved |
  | `make publish STOP=pre-cmake` | 10.3 s | 31 artifacts |
  | `make root PKGS="baselayout xsh xinit musl"` | 21.1 s | 324 files, 12 ELF, 0 failures |

## Linux amd64 host campaign

**Done means:** on the Linux amd64 host, every package in `packages/` builds
for `x86_64-linux-musl` from `make clean`. There are no exclusions and no
skipped recipes: fix a failing recipe, never drop it. The world then
publishes to the local mirror, composes a root, and produces an installer
image that passes the QEMU proof:

```sh
make clean
make fetch
make seed
make mirror &                 # leave running; `kill %1` at the end
make build                    # ARCH defaults to x86_64 here; no PKGS/STOP = all 69 packages
make publish
make root PKGS="baselayout xsh xinit musl"
make installer-image          # once parameterized by arch (below)
make installer-qemu-test
```

Start from the README sequence: clone `laputa` and `xsh` side by side, then
`make host-xsh`. Work through the list roughly in order, checking each item
off here with its measurement or result.

- [ ] **Host tools.** `make host-xsh` builds `xsh-test` natively for
  `linux/amd64`, and `.out/host/x86_64/xsh` runs. A following `make seed`
  finishes cargo in about a second, because the compiled units are shared.
  `make check`, `make test-pm`, `make test-system` and `make test-xinit` pass
  with the host tools. `make mirror-test` needs a host cargo, so on a
  Rust-free host give it an `xsh-test` path like `host-mirror`.
- [ ] **Docker ownership.** Rootful Docker leaves root-owned files under
  `.out/`. `make clean` and `make root` handle that already. Confirm that
  `make publish` reads the store, and decide whether containers should run as
  the host user instead. Rootless Docker avoids the problem.
- [ ] **CPU baseline.** The `cc` wrapper builds userland with
  `-march=x86-64-v3`, and package proofs run the binaries natively. Confirm
  that the host has AVX2, BMI2 and MOVBE (`grep -o 'avx2\|bmi2\|movbe'
  /proc/cpuinfo | sort -u`), or change the policy in
  `packages/llvm-toolchain`.
- [ ] **Pre-cmake first.** `make build STOP=pre-cmake` (31 packages) gives a
  fast signal on the seed, package-tools and the toolchain for x86_64.
- [ ] **cmake, linux and the rest of the world.** `make build` with no
  selection. Record the per-package failures and their fixes. Expect x86-only
  paths to be exercised for the first time:
  - the kernel's x86 kbuild (`packages/linux/PKGBUILD-x86_64.xsh`), including
    the new `rq-offsets.h` generation and the `-march` fixes, all unverified;
  - the libnl3 and wpa_supplicant triple fix;
  - gnu-stubs against the x86_64 builtins;
  - pixman's SIMD paths.
- [ ] **Kernel command line.** `base-x86_64.fragment` has
  `# CONFIG_CMDLINE_BOOL is not set`, while aarch64 builds in
  `root=LABEL=LAPUTA_ROOT rw ...`. Set an x86 equivalent (with
  `console=ttyS0`) or have the installer and QEMU pass one.
- [ ] **Kbuild speed and a persistent kbuild cache.** Measure the linux build
  cold and warm. Keep the kbuild plan cache under `.out/cache/linux-kbuild`
  (mounted into the build container, removed by `make clean`) instead of
  throwaway trees or `/var/cache/laputa`.
- [ ] **Kernel headers as a build-only dependency.** libffi, libnl3, libevdev,
  mtdev, libudev-zero and wpa_supplicant list `linux` in `deps`, which pulls
  the kernel into runtime roots. Make them take kernel headers as a
  build-only dependency.
- [ ] **Unused build dependencies.** Drop tailscale's build-host
  `llvm-toolchain`, foot's `utf8proc` (grapheme clustering is disabled) and
  m4's `musl` (m4 is an XSH script).
- [ ] **Linux tests make target.** The kbuild tests under
  `packages/linux/tests` have no make target, and on macOS they fail writing
  `/var/cache/laputa`. Add a target whose cache lives under `.out/`.
- [ ] **Installer from the local mirror.** `build-installer-common.xsh` and
  `build-installer-image.xsh` still default `LAPUTA_REPO_URL` to the remote
  mirror. Point them at the local mirror and parameterize them by arch:
  - aarch64 first, then rebuild x86_64 through the same container and
    local-mirror path (D5);
  - fix the serial console, the cmdline override and `forbidden_packages`
    enforcement.
- [ ] **QEMU proof.** The installer and the profile CLI are aarch64- and
  macOS-only today:
  - `system/docker.xsh` pins `linux/arm64` and `profile_seed_arch`;
  - `system/qemu.xsh` runs `qemu-system-aarch64` with HVF and Cocoa.

  Add an x86_64 path that uses `qemu-system-x86_64` with KVM on the host, and
  prove the installer image boots and installs.
- [ ] **Two musl and bison checks** (both arches; the audit raised them):
  - musl excludes generic sources by bare file stem, so `src/thread/<arch>/clone.s`
    may knock out `src/linux/clone.c` and leave libc without `clone()`;
  - `pm/target.xsh::lp64_musl_abi` sets `signed_wchar_t: true`, which is
    wrong for aarch64.
- [ ] **Docs consolidation.** One README, AGENTS.md and `docs/` set. Fix the
  stale docs:
  - `docs/PM.md` still says `repo/<package>`, `tests/xsh/` and
    `make test-native`;
  - `docs/LAPUTA.md` describes the sibling `packages` repo;
  - `docs/CORE-INFRASTRUCTURE.md` says "aarch64-only";
  - also update `INSTALLER.md`, `docs/QEMU.md`, `docs/MAKE.md` and the xinit
    docs.
- [ ] **Deduplicate the laputa scripts:** the GPT helpers, `env_value`,
  `run_argv`, `remove_tree` and the installer wrappers.
- [ ] **Container user:** containers run as root, so on Linux `.out/` gets
  root-owned files (`make clean` and `make root` delete through a container).
  Evaluate running builds as the host user (`--user $(id -u):$(id -g)`).
  Check first that payload ownership in packages stays root:root (PM must
  normalize ownership when packing) and that no recipe needs root at build
  time. Adopt it only if the whole world still builds identically.

Known open XSH items: none blocking. The `check.desugar` pipeline error is
fixed in xsh (non-call value stages get `check.ambiguous-grouping` or
`check.pipeline-stage`).
- An incremental seed build once failed to link `xshi` while XSH was being
  committed to concurrently. The rerun passed.

## Decisions (settled 2026-10-03)

- **D1. Fetch once, then offline.**
  - `make fetch` is the only networked step: upstream sources, the LLVM
    seed, the Rust dist, vendored crates and the base image go into
    `.cache/`, each sha256-verified.
  - Everything after that runs with `--network none` against the local
    mirror.
  - Nothing ever contacts `laputa.17166969.xyz`.
- **D2. The seed xsh is built locally,** never taken from a published release.
  xsh changes do not rebuild the world (revised 2026-10-03; development
  speed comes first).
  - `make seed` builds the current `../xsh` checkout. There is no pin and no
    `seed.lock`.
  - Artifact keys exclude the build-time xsh and the PM code. A key covers
    the target, the recipe and its sources, the keys of its build
    dependencies (`mkdeps`, not runtime `deps`), and a global `BUILD_EPOCH`.
  - Each artifact's metadata records which xsh and PM revision built it, for
    provenance; that record is not part of the key.
  - To force rebuilds, bump `BUILD_EPOCH` (all packages) or a recipe's `rel`
    (one package).
- **D3. Keep the pinned prebuilt LLVM 23.1.0-rc2 seed,** cached by
  `make fetch`. LLVM from source is out of scope.
- **D4. Fresh import:** the files of `packages`, `mirror` and `xinit` are
  copied into the monorepo in one commit, without their history. The old
  repos stay as they are.
- **D5. Delete the legacy x86_64 installer route.** The Linux amd64 phase
  rebuilds it through the same container and local-mirror path as aarch64,
  parameterized by arch.
- **D6. The in-world `xsh` package packages the seed build:** the static
  musl binaries and core, sha256-checked and served by the local mirror. It
  is not compiled in-world.
- **D7. The mirror gains a local-only mode:** filesystem storage, plain HTTP
  on 127.0.0.1, no auth. Production S3 and WebAuthn behavior stays.
- **D8. Package identity is content-addressed** (settled 2026-10-03).
  - Published payload, metadata and proof objects are named by artifact key
    (and proof key) and are never replaced.
  - The index row is the only mutable pointer. Publishing a rebuild under the
    same `ver`-`rel` replaces the row, not the objects.
  - A row behind the remote's `ver`-`rel` is refused. `ver`-`rel` is for
    display and ordering; roots and generations follow keys.
