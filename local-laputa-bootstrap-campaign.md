# Local Laputa bootstrap campaign

## Summary (Linux amd64 host, 2026-10-04)

From `make clean` on a Linux amd64 host with only git, make, Docker, KVM and
QEMU, the whole Laputa world (70 packages for `x86_64-linux-musl`, with no
exclusions) builds and proves in 4m27s. It then publishes to the local mirror
and composes a root. The installer image installs and boots under KVM, and
the canonical `qemu-dwl-foot` proof drives dwl and foot under
`qemu-system-x86_64` with KVM. All native suites, `make check`, `make
mirror-test` and XSH's Linux gate pass. A no-change `make build` takes 7 s
and builds nothing. Timings and every failure fixed are in the run log below.

- **Built:** host tools in 129 s, the seed in 17 s, the world in 267 s,
  publish in 9 s, root in 15 s. Installer QEMU proof 23 s, profile build plus
  proof 70 s.
- **New:** a `linux-headers` package (byte-identical to `make headers_install`
  on both arches), arch-neutral installer and profile CLIs, `make test-linux`,
  `make mirror-test` without host Rust, and a persistent Kbuild plan cache.
- **Real bugs fixed beyond the build:** musl's missing `clone()`, x86
  `asm/stat.h` and six other clobbered headers, both arches' truncated
  built-in kernel command line, host mode bits leaking into keys and payloads,
  aarch64 `wchar_t` signedness, an unenforced `forbidden_packages`, and a
  broken in-world `getent`.
- **XSH changes** (`../xsh`, local commits): `fs.write_atomic` keeps
  plain-write modes; host musl builds no longer force rust-lld; a racy net
  test waits instead of cancelling.
- **Host change:** `doas apk add qemu-hw-display-virtio-gpu
  qemu-hw-display-virtio-gpu-pci` (Alpine ships QEMU's virtio GPU as separate
  packages; the profile proof needs it). `apk del` reverts it.
- **Left open:**
  - aarch64 was not rebuilt or booted on this host. Its shared paths changed:
    the profile CLI, installer, linux-headers, musl, PM modes, and the
    kernel's built-in command line.
  - The x86_64 kernel config is still hand-merged; Kconfig would change about
    90 symbols (D12).
  - The profile proof's screenshot is taken after foot exits, so it shows a
    blank session.
  - `make installer-qemu-manual` defines `main` without calling it and
    assumes aarch64.
  - xinit accepts unknown service fields instead of rejecting them.
  - PM's `repo plan` defaults `--target` to aarch64.
  - Removing the `-lgcc_s` name altogether needs a Rust std built with LLVM
    libunwind; `gnu-stubs` already provides that soname from libunwind.

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

- [x] **Host tools.** `make host-xsh` builds `xsh-test` natively for
  `linux/amd64`, and `.out/host/x86_64/xsh` runs. A following `make seed`
  finishes cargo in about a second, because the compiled units are shared.
  `make check`, `make test-pm`, `make test-system` and `make test-xinit` pass
  with the host tools. `make mirror-test` needs a host cargo, so on a
  Rust-free host give it an `xsh-test` path like `host-mirror`.
  - **Result:** Done: `make host-xsh` 140 s cold; the following `make seed` finished cargo in 0.16 s. `make mirror-test` runs in `xsh-test` on Linux.
- [x] **Docker ownership.** Rootful Docker leaves root-owned files under
  `.out/`. `make clean` and `make root` handle that already. Confirm that
  `make publish` reads the store, and decide whether containers should run as
  the host user instead. Rootless Docker avoids the problem.
  - **Result:** Done (D10): `make publish` could not read `plan.json`, which XSH's `fs.write_atomic` created 0600. XSH now keeps plain-write modes. Containers stay root.
- [x] **CPU baseline.** The `cc` wrapper builds userland with
  `-march=x86-64-v3`, and package proofs run the binaries natively. Confirm
  that the host has AVX2, BMI2 and MOVBE (`grep -o 'avx2\|bmi2\|movbe'
  /proc/cpuinfo | sort -u`), or change the policy in
  `packages/llvm-toolchain`.
  - **Result:** Done: the host has AVX2, BMI2 and MOVBE; native proofs pass.
- [x] **Pre-cmake first.** `make build STOP=pre-cmake` (31 packages) gives a
  fast signal on the seed, package-tools and the toolchain for x86_64.
  - **Result:** Done: 31 packages built and proved in 79 s.
- [x] **cmake, linux and the rest of the world.** `make build` with no
  selection. Record the per-package failures and their fixes. Expect x86-only
  paths to be exercised for the first time:
  - the kernel's x86 kbuild (`packages/linux/PKGBUILD-x86_64.xsh`), including
    the new `rq-offsets.h` generation and the `-march` fixes, all unverified;
  - the libnl3 and wpa_supplicant triple fix;
  - gnu-stubs against the x86_64 builtins;
  - pixman's SIMD paths.
  - **Result:** Done: all 70 packages (69 plus the new `linux-headers`) build and prove. The failures and fixes are in the run log below.
- [x] **Kernel command line.** `base-x86_64.fragment` has
  `# CONFIG_CMDLINE_BOOL is not set`, while aarch64 builds in
  `root=LABEL=LAPUTA_ROOT rw ...`. Set an x86 equivalent (with
  `console=ttyS0`) or have the installer and QEMU pass one.
  - **Result:** Done: x86_64 builds in `root=PARTLABEL=LAPUTA_ROOT rootwait rw console=ttyS0 loglevel=4 init=/init`. The scratch Kbuild had truncated both arches' `CONFIG_CMDLINE` to `root`; aarch64 now uses `PARTLABEL` too (the kernel cannot resolve `LABEL=` without an initramfs).
- [x] **Kbuild speed and a persistent kbuild cache.** Measure the linux build
  cold and warm. Keep the kbuild plan cache under `.out/cache/linux-kbuild`
  (mounted into the build container, removed by `make clean`) instead of
  throwaway trees or `/var/cache/laputa`.
  - **Result:** Done: `.out/cache/linux-kbuild` is mounted at the recipe's cache path in world and profile containers. With only the kernel rebuilding, `make build` takes 1m49s cold and 1m48s with a plan-cache hit; the compile dominates.
- [x] **Kernel headers as a build-only dependency.** libffi, libnl3, libevdev,
  mtdev, libudev-zero and wpa_supplicant list `linux` in `deps`, which pulls
  the kernel into runtime roots. Make them take kernel headers as a
  build-only dependency.
  - **Result:** Done (D11), as a separate `linux-headers` package that matches `make headers_install` byte for byte on both arches. It also fixed x86_64 `asm/stat.h` and six other headers, and removed the fake-header and `-D__user=` workarounds from five recipes.
- [x] **Unused build dependencies.** Drop tailscale's build-host
  `llvm-toolchain`, foot's `utf8proc` (grapheme clustering is disabled) and
  m4's `musl` (m4 is an XSH script).
  - **Result:** Done.
- [x] **Linux tests make target.** The kbuild tests under
  `packages/linux/tests` have no make target, and on macOS they fail writing
  `/var/cache/laputa`. Add a target whose cache lives under `.out/`.
  - **Result:** Done: `make test-linux` (kbuild plus headers_install tests), part of `make test`.
- [x] **Installer from the local mirror.** `build-installer-common.xsh` and
  `build-installer-image.xsh` still default `LAPUTA_REPO_URL` to the remote
  mirror. Point them at the local mirror and parameterize them by arch:
  - aarch64 first, then rebuild x86_64 through the same container and
    local-mirror path (D5);
  - fix the serial console, the cmdline override and `forbidden_packages`
    enforcement.
  - **Result:** Done (D9) for x86_64. The serial console, the cmdline and the image sizing are fixed. aarch64 shares the code path but was not rerun here.
- [x] **QEMU proof.** The installer and the profile CLI are aarch64- and
  macOS-only today:
  - `system/docker.xsh` pins `linux/arm64` and `profile_seed_arch`;
  - `system/qemu.xsh` runs `qemu-system-aarch64` with HVF and Cocoa.
  - **Result:** Done: `make installer-qemu-test` and `make profile-test` pass under `qemu-system-x86_64` with KVM.

  Add an x86_64 path that uses `qemu-system-x86_64` with KVM on the host, and
  prove the installer image boots and installs.
- [x] **Two musl and bison checks** (both arches; the audit raised them):
  - musl excludes generic sources by bare file stem, so `src/thread/<arch>/clone.s`
    may knock out `src/linux/clone.c` and leave libc without `clone()`;
  - `pm/target.xsh::lp64_musl_abi` sets `signed_wchar_t: true`, which is
    wrong for aarch64.
  - **Result:** Done: both were real. musl lost the public `clone()` on both arches (fixed, and the proof now links against it). aarch64 `wchar_t` is unsigned (fixed; bison `rel` bumped).
- [x] **Docs consolidation.** One README, AGENTS.md and `docs/` set. Fix the
  stale docs:
  - `docs/PM.md` still says `repo/<package>`, `tests/xsh/` and
    `make test-native`;
  - `docs/LAPUTA.md` describes the sibling `packages` repo;
  - `docs/CORE-INFRASTRUCTURE.md` says "aarch64-only";
  - also update `INSTALLER.md`, `docs/QEMU.md`, `docs/MAKE.md` and the xinit
    docs.
  - **Result:** Done: one current set; `docs/LAPUTA.md` folded into `docs/CORE-INFRASTRUCTURE.md`.
- [x] **Deduplicate the laputa scripts:** the GPT helpers, `env_value`,
  `run_argv`, `remove_tree` and the installer wrappers.
  - **Result:** Done: `installer/host.xsh` and `system.image`'s exported GPT helpers; the installer ISO is byte-identical before and after.
- [x] **Container user:** containers run as root, so on Linux `.out/` gets
  root-owned files (`make clean` and `make root` delete through a container).
  Evaluate running builds as the host user (`--user $(id -u):$(id -g)`).
  Check first that payload ownership in packages stays root:root (PM must
  normalize ownership when packing) and that no recipe needs root at build
  time. Adopt it only if the whole world still builds identically.
  - **Result:** Evaluated (D10): kept root. `make root` chroots, and the only unreadable state was the 0600 atomic write, now fixed in XSH.

Known open XSH items: none blocking. The `check.desugar` pipeline error is
fixed in xsh (non-call value stages get `check.ambiguous-grouping` or
`check.pipeline-stage`).
- An incremental seed build once failed to link `xshi` while XSH was being
  committed to concurrently. The rerun passed.

## Linux amd64 run log (2026-10-04)

Host: 32 cores, 60 GB, Alpine with rootful Docker 29.5 (`linux/amd64`), KVM.
The CPU has AVX2, BMI2 and MOVBE.

Final clean run, one step at a time from `make clean` (wall seconds; `.cache/`
already held the sources):

| Step | Time | Result |
|---|---|---|
| `make clean` | <1 | `.out/`, `target/` and the Laputa images removed |
| `make host-xsh` | 129 | static `xsh`/`xshi`/`xsht` in `.out/host/x86_64` |
| `make fetch` | 4 | 58 sources cached, 0 fetched |
| `make seed` | 17 | cargo reused the host-xsh units; then package-tools |
| `make mirror` | 35 | first run builds the mirror; listening on 127.0.0.1:3000 |
| `make build ARCH=x86_64` | 267 | 70 packages built and proved |
| `make publish` | 9 | 70 artifacts |
| `make root PKGS="baselayout xsh xinit musl"` | 15 | 324 files, 12 ELF, 0 failures; the root's xsh runs |
| `make installer-image` | 8 | 137 MB ISO (9.4 MB kernel) |
| `make installer-qemu-test` | 23 | KVM: install, boot the disk, DHCP, SSH into dropbear |
| `make profile-build` | 20 | `qemu-dwl-foot` image |
| `make profile-test` | 50 | KVM: mdevd, seatd, dwl, foot; QMP `laputa` reaches foot; screenshot |
| `make check` | 34 | clean, extensionless XSH programs included |
| `make test-pm` | 11 | 196 passed |
| `make test-system` | 16 | 53 passed |
| `make test-xinit` | 8 | 22 passed |
| `make test-linux` | 1 | 24 passed |
| `make mirror-test` | 41 | 20 passed, in `xsh-test` |
| `make build ARCH=x86_64` again | 7 | no-op: 0 packages built, 70 reused |

XSH (`../xsh`): `cargo dev test linux --ci` passes (836 Rust integration
tests, 319 unit tests), and so do the native suites for the changed modules.
The first try at this run failed `make test-linux`: the kbuild tests shared the
build containers' root-owned plan cache. They have their own directory now, and
the remaining steps passed on the rerun.

Failures found and fixed, in order:
- The `lint` commit had left bison/flex local-source pins and the golden plan
  fixture stale. The cargo proof test assumed an aarch64 host.
- `make publish` could not read `plan.json`: XSH's `fs.write_atomic` always
  created 0600 files (tempfile's default). Fixed in XSH.
- linux (x86): vmlinux whole-archived the EFI stub library's private lib/
  copies (duplicate symbols). Fixed in the x86-only archive input list.
- linux (x86): the hand-merged config enabled USB audio and UVC under menus
  that were off, so `SND_HWDEP`/`VIDEOBUF2_*` were never built (undefined
  symbols). Those symbols are now resolved as Kconfig does (D12).
- linux: the bzImage payload was an uncompressed "stored" gzip stream; it is
  now gzip -9 (28.6 MB to 9.7 MB).
- linux: Kbuild's `.config` reader cut string values at their first `=`, so
  both arches' built-in `CONFIG_CMDLINE` was just `root`.
- tmux: the proof joined paths without a slash, and needed a shell that its
  proof root never has.
- The kernel package installed raw uapi headers, clobbering seven x86 asm
  headers, `asm/stat.h` among them, with generic wrappers. This became
  `linux-headers` (D11), and five recipes lost their fake-header and
  `-D__user=` workarounds.
- PM: keys and staged checkout inputs carried host mode bits. The host's
  setgid checkout put 02755 directories into baselayout and the profile
  overlay, so composition conflicted. Git's mode model now applies.
- musl: arch overrides replaced generic sources by bare stem across
  subsystems, so `libc.so` had no public `clone()` on either arch.
- aarch64 `wchar_t` was declared signed in PM's musl ABI table.
- baselayout's `getent` and the profile boot hook failed to check on current
  XSH. Neither was ever checked: `make check` only saw `*.xsh` files.
- Installer: mirror-based roots (D9), x86_64 serial console, block-count image
  sizing, a nonexistent `linux-virt-amd64` default.
- qemu-dwl-foot: arch-neutral host targets. The QEMU supervisor counted a
  zombie QEMU as live. q35's default VGA was what screendump captured.
  `forbidden_packages` was never enforced.
- XSH: `.cargo/config.toml` forced rust-lld for the host musl triple, so host
  cargo could not link proc-macros. And a net test raced its own cancel.

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
- **D9. The installer takes its roots from the local mirror** (2026-10-04),
  the way `make root` does: the host plans the target, installer, and tools
  roots against the mirror, requires every node to be an exact mirror
  artifact, imports them into a fresh store under the installer work tree,
  and composes the three roots on the host. Composing is file extraction, so
  no container writes root-owned files there, and the installer no longer
  needs the arm64-only profile Docker adapter. `make installer-image` and
  `make installer-qemu-test` take `ARCH` and need `make mirror` and `make
  publish`.
- **D10. Rootful Docker stays; atomic writes keep plain-write modes**
  (2026-10-04). The only state the host could not read was `plan.json`, which
  XSH's `fs.write_atomic` created 0600 (tempfile's default). XSH now gives an
  atomically written file the mode a plain write would. Running containers
  as the host user would also break `make root`'s chroot inspection, so the
  container user stays root, and `make clean`/`make root` keep deleting
  through a container.
- **D11. Kernel headers are their own package** (2026-10-04). `linux-headers`
  installs the uapi trees from the pinned kernel tarball with no compiler,
  and every package that compiles against `<linux/...>` or `<asm/...>` takes
  it as a build dependency (`build-essential-native` keeps it at runtime).
  `linux` ships only the kernel and its config, so a kernel config or Kbuild
  change rebuilds the kernel alone, and no runtime root pulls the kernel in
  through libnl3, libffi, and the like. It applies Kbuild's wrapper rule
  (wrap asm-generic's mandatory-y and the arch's generic-y only where the
  arch has no header), which fixes x86_64's `asm/stat.h`, `siginfo.h`,
  `swab.h`, `msgbuf.h`, `sembuf.h`, `shmbuf.h` and `kvm_para.h`. The old
  install replaced those with asm-generic wrappers, and generic `struct stat`
  does not match x86_64's.
- **D12. The x86_64 kernel config keeps its hand-merged fragment** (2026-10-04),
  with only the symbols that broke the link resolved as Kconfig resolves
  them (USB audio and UVC under menus that are off). Kconfig `olddefconfig`
  with the pinned LLVM still reports about 90 symbols it would drop or
  change, mostly invisible `n` entries. Normalizing the whole fragment would
  also change generated headers the scratch Kbuild depends on, so it stays
  open.
- **D13. Upgrade every package to its latest stable release** (2026-10-04),
  with three exceptions:
  - LLVM stays on the pinned prebuilt 23.1.0-rc2 (D3). No newer prebuilt is
    published, and making one means building LLVM and publishing a release.
  - mdevd stays at 0.1.8.2: 0.1.8.3 is announced, but its tarball returns 404.
    skalibs goes to 2.15.1.0.
  - tailscale goes to 1.102.4, the newest on its stable package index.
  The kernel goes to 7.2.9 (7.0 is EOL). wlroots 0.20 and dwl 0.9 move
  together, and fontconfig 2.18 moves with muon 0.7. Forks under
  laputa-systems are never pushed to: a recipe that needs fork commits on a
  new upstream release carries them as patches.
- **D14. Real Mesa replaces the `mesa-minimal` shim, with generated sources
  vendored** (2026-10-04). Mesa's ~60 Python/Mako-generated outputs go under
  `files/generated/`, regenerated on the host with the documented command.
  Python is not added to the build world.
- **D15. terminfo without ncurses comes from our own XSH terminfo compiler**
  (2026-10-04). It compiles ncurses' pinned `terminfo.src` into the binary
  database.
- **D16. deno builds from source with cargo** (2026-10-04), linking rusty_v8's
  published musl static library, because deno publishes only glibc builds.
