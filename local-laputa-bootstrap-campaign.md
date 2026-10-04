# Local Laputa bootstrap campaign

Goal: one Laputa monorepo, built from a clean checkout on a local machine, end
to end:

- no dependence on `https://laputa.17166969.xyz`;
- sources served by a locally run mirror over plain unauthenticated HTTP;
- a locally built seed xsh;
- fast, cached rebuilds.

This macOS pass ends once the first packages build from the local seed. It
stops before `cmake` and `linux`. A Linux amd64 host finishes the world build
afterwards.

Laputa and XSH are developed together: Laputa is the distribution, and XSH is
the language that powers it. Changes to xsh and xsht that make the
distribution simpler are in scope, and the Laputa docs say so.

Out of scope:
- GitHub CI.
- Building the mirror as a Laputa package (no Deno package). The mirror is a
  host tool the bootstrap runs, not something it builds.

## Where things stand (research, 2026-10-03)

### Repositories

| Repo | Commits | Role |
|---|---|---|
| `laputa` | 41 | profile CLI (`laputa/`), installer, QEMU proof, `Dockerfile.package-tools`, `bootstrap-llvm-seed.xsh` |
| `packages` | 199 | `pm.xsh` and `pm/` (28 modules, ~11.7k lines); `repo/` (70 recipes, `linux/` alone is 10.5k lines) |
| `mirror` | 15 | Rust server for index, packages, metadata and per-package source tarballs. S3/R2 only, WebAuthn and token auth for writes. |
| `xinit` | 6 | `xinit.xsh` (PID 1 and service manager), with tests and docs |

There are no submodules. Everything assumes sibling checkouts (`../packages`,
`../xsh`, `$HOME/d/laputa-systems/...`).

### Network dependencies today

- **Remote mirror:**
  - `pm/remote.xsh::default_repo_url` is the default unless
    `XSH_PM_OFFLINE=1`;
  - `build-installer-common.xsh` and `build-installer-image.xsh` use it for
    the x86_64 installer, `linux_tarball` and `install_remote_packages`;
  - PM reads `.env` for `LAPUTA_TOKEN`.
- **Seeds fetched from GitHub** (all still reachable as of 2026-10-03):
  - `laputa-systems/llvm-prebuilt-musl` `clang+llvm-23.1.0-rc2` (aarch64 and
    x86_64);
  - `laputa-systems/xsh` release `d09c6c33` (xsh, xshi, xsht, core);
  - `github.com/laputa-systems/xinit/raw/c6af710…`, three commits behind
    xinit HEAD.
- **Base image:** `alpine:3.21@sha256:48b0…` plus unpinned
  `apk add build-base ca-certificates curl e2fsprogs util-linux xz zlib`.
- **Upstream sources:** about 60 recipes pull from GNU, kernel.org,
  freedesktop, GitHub, static.rust-lang.org (cargo is a prebuilt Rust
  toolchain), pkgs.tailscale.com (a prebuilt binary) and others.
- **Hidden fetch at build time:** `sudo-rs` runs `cargo build` against
  crates.io during the build.

### Local state

- Nothing is cached locally: no source cache, no local repo, no mirror data.
- The only local LLVM tarball (22.1.8) matches no pin.
- OrbStack's Docker daemon is not running.

### How build and caching work today

- **Plan:** `repo plan` loads all 70 recipes, fetches the remote `index.json`
  (unless offline), and hashes the PM tree, the xsh binaries and the core
  applets into the *executor identity*. Artifact key = target + package +
  recipe hash + executor + dependency keys.
- **Build:** `execute.build_plan` builds level by level with `par-map`. There
  is no chroot. Each node unpacks and then copies its dependency closure into a
  temp root, seeds host xsh, runs `xsht trace` with the host `PATH` appended,
  and stores
  `v1/sha256/<key>/{artifact.json,payload.tar.gz,metadata.json,proof.json}`.
- **No download cache:** sources download into a fresh temp work dir every
  build.
- **Any change to `pm/*.xsh`, the xsh binaries or the core rebuilds the
  entire world,** Linux included. That is incompatible with co-developing XSH.
- **Repeated hashing:** payloads are hashed many times per build (receipt
  closure, double lookups, plan re-validation per node).
- **Kbuild caches** live in throwaway trees or at an unmounted
  `/var/cache/laputa/linux-kbuild`.

### Build order

| Level | Packages |
|---|---|
| L0 | musl, xsh, baselayout, ca-certificates, hwdata, tllist, xkeyboard-config, font-ttf-hack |
| L1 | llvm-toolchain, m4, gnu-stubs, xinit, laputa-fs, laputa-pm |
| L2 | samurai, bison, flex, pkgconf, cargo, alsa-lib, less, iptables, eudev-lite, mdevd |
| L3 | **cmake**, muon, **linux**, tailscale |

The macOS stop line is the end of L2, plus any L3+ package that needs neither
cmake nor linux.

## Bootstrap blockers and risks

- **No fatal blocker.** Every pinned seed URL still resolves.
- **The LLVM seed is a prebuilt binary** from our own GitHub repo. LLVM is
  never built from source here (decision D3).
- **The Docker daemon must be running** (OrbStack, `linux/arm64`).
- **The Alpine base image and apk packages need network once.** apk is
  unpinned, so an image rebuild can drift.
- **Every recipe upstream must be fetched once.** Dead upstream URLs show up
  only when we fetch them all (step B1).
- **The world rebuilds** whenever the PM code or xsh changes (decision D2).
- **`sudo-rs` must be vendored** to build offline.
- **Done:** the user deleted `laputa/.env`, which held live
  `TAILSCALE_AUTH_KEY` and `LAPUTA_TOKEN` values. PM still reads `.env`
  files; delete that code.

## Target design

### Monorepo layout

Import the files of `packages`, `mirror` and `xinit` in one commit, without history (D4).

```
laputa/
  Makefile            single entry point (below)
  pm.xsh  pm/         package manager                 (packages/pm.xsh, pm/)
  packages/<name>/    recipes                         (packages/repo/*)
  system/             profile CLI modules             (laputa/laputa/*)
  profiles/ guest/ boot/ installer/
  xinit/              xinit.xsh, tests, docs          (xinit/*)
  mirror/             Rust mirror server, host tool   (mirror/*)
  seed/               seed.lock and seed scripts
  tests/ docs/ tools/
  .out/               ALL derived state (gitignored)
  .cache/             fetched inputs: sources by sha256, seed artifacts, saved images (gitignored)
```

- The `xinit` and `laputa-*` recipes take their sources from the tree, through
  `repository/` sources, instead of from GitHub.
- `xsh` stays its own repo at `XSH_ROOT ?= ../xsh`. The seed is built from a
  pinned commit of it (decision D2).

### Make targets

- **`make clean`:** removes every piece of derived state:
  - `.out/`, which holds the PM store, work dirs, local mirror package data,
    logs, kbuild caches and installer outputs;
  - Laputa Docker volumes and `laputa-*` images, through
    `docker volume rm` / `docker image rm` against an explicit list.

  It keeps `.cache/`.
- **`make distclean`:** `clean`, then also deletes `.cache/`.
- **`make fetch`:** the only step that touches the network. It downloads every
  pinned input into `.cache/` and verifies each sha256:
  - each recipe's upstream sources for the selected arch;
  - the LLVM seed;
  - the Rust dist;
  - the vendored crates;
  - the base image, saved with `docker save`.

  It never contacts the Laputa mirror.
- **`make seed`:**
  - builds static musl `xsh`/`xshi`/`xsht` and the core tarball from
    `XSH_ROOT` at the commit pinned in `seed/seed.lock`, in xsh's
    `Dockerfile.test` image with the release profile;
  - builds the package-tools image from local inputs only (no GitHub `ADD`),
    or loads it from the saved tar.
- **`make mirror`:**
  - runs `mirror` locally from `.out/mirror` in local mode: plain HTTP on
    127.0.0.1, no auth, filesystem storage;
  - serves `.cache/sources` read-only by sha256;
  - accepts package publishes without a token.
- **`make plan` / `make build [PKGS=…|STOP=pre-cmake]`:**
  - PM plans offline against the local mirror;
  - builds run in arm64 Docker with `--network none`;
  - results publish into the local mirror.
- **`make test`:** native suites for PM, laputa and xinit (`xsht test`).
- **`make check`:** `xsht check` and `xsht lint` across the tree.

### Sources and caching

- **Downloads are content-addressed** at `.cache/sources/sha256/<hash>`. A
  fetch first tries the local mirror (`LAPUTA_MIRROR`, by sha256), then the
  cache. Only `make fetch` contacts upstreams.
- **URL rewriting stays outside fingerprints.** Artifact keys hash the source
  string and checksum as today, so moving to the local mirror changes no key.
- **No remote mirror default** and no `.env` reading. Publishing to
  `http://127.0.0.1` local mode needs no token.
- **Executor identity per decision D2:** artifacts key on the pinned seed
  xsh, not the host's dev xsh build. The PM identity covers only the modules
  that affect build outputs; changes to the PM CLI, plan or remote code
  rebuild nothing. `BUILD_EPOCH` is the explicit way to invalidate.
- **Hash each payload once per process.** Trust store entries whose
  directory key was verified when they were committed; plan validation runs
  once per build, not per node.
- **Build roots:** unpack the dependency closure once per node, with no
  second copy. Proof roots reuse unpacked dependency payloads through a
  per-build unpack cache.
- **Persistent kbuild plan cache** under `.out/cache/linux-kbuild`. This
  mostly matters on the Linux host.

## Lanes (up to 4 in parallel, Opus 5.5 medium)

**Phase 0, serial (integrator): consolidation.**
- Copy in the files of the three repos (D4).
- Move them into the layout and rewrite every sibling path:
  - `xsht-config.ini` module paths;
  - the Makefiles and their merge into one;
  - `docker.xsh` `--build-context`;
  - the `packages_root()` home path;
  - the AGENTS.md files.
- Delete the stray files the research found:
  - `plan2.md`;
  - `repo/run-package-build.trace` and the two `run-package-build.xsh`
    scripts;
  - `prepare-proof-rootfs-package-upgrade.xsh`;
  - `tools/linux-kbuild-oracle.py` and its fixture;
  - `.envrc`;
  - stale `.gitignore`/`.dockerignore` entries;
  - `Dockerfile.test-local`.
- Gate: every module checks (`xsht check`), and all three test suites pass
  on the host.
- **Done (2026-10-03).** The layout:
  - `pm.xsh`, `pm/`;
  - `packages/<name>/`;
  - `system/` (module names `system.*`), `laputa.xsh`;
  - `profiles/`, `guest/`, `boot/`;
  - `installer/` plus the root `build-installer-*`/`installer-*` scripts;
  - `xinit/`;
  - `mirror/`;
  - `tests/{pm,system,integration}/`;
  - `docs/`.

  The PM repository root is the directory that holds `pm.xsh` and
  `packages/`. Recipe modules import as `packages.*`. Containers mount the
  one checkout at `/src/laputa`. `XSH_ROOT` replaces `XSH_SOURCE_ROOT` and
  `LAPUTA_PACKAGES_ROOT`. The `xinit` recipe takes its source from
  `repository/xinit/xinit.xsh`.

  There is one root `Makefile`:
  - `check`;
  - `test` (`test-pm`, `test-system`, `test-xinit`);
  - `clean` (`.out/`, `target/`, mirror frontend outputs);
  - `profile-*`, `test-pm-*`, `installer-*`, `mirror-*`.

  There is also one `xsht-config.ini` and one `AGENTS.md`. The legacy
  x86_64 installer route and the `.env` reading in PM are deleted. xinit
  is ported to current XSH: it had ~100 check diagnostics, and its tests
  no longer loaded.

  Gates:
  - `make check`: clean;
  - PM: 153 passed, 2 skipped;
  - system: 36 passed;
  - xinit: 22 passed;
  - mirror `cargo test`: 37 passed;
  - no sibling-path references remain.

  Deferred to later phases:
  - **Remote-mirror defaults stay** in `pm/remote.xsh` and in the
    installer's `LAPUTA_REPO_URL` (lanes B and C, then the Phase 3
    installer work).
  - **GitHub xsh release `ADD`s stay** in `Dockerfile.package-tools`,
    `Dockerfile.pm-test` and `packages/xsh` (lane C).
  - **The package-tools image build was not exercised.** Docker was not
    running, and the build context is now the monorepo root behind
    `.dockerignore`.
  - **Some docs still describe the pre-monorepo commands:** `docs/PM.md`,
    `LAPUTA.md`, `MAKE.md` and `QEMU.md` (Phase 3).
  - **xinit now needs post-2026-09 XSH APIs,** so the seed pin must not be
    older than the current `../xsh`.

**Phase 1, 4 lanes in parallel.** File ownership is disjoint.

- **A. Local mirror** (`mirror/`):
  - a `Storage::Fs` backend;
  - `--local DIR` mode: plain HTTP, 127.0.0.1 only, no auth, no env panics,
    no frontend;
  - a read-only `sources/sha256/<hash>` route over the source cache;
  - tests;
  - `make mirror`.
  - Production S3/WebAuthn behavior stays unchanged.
- **B. PM sources and offline** (`pm/sources.xsh`, `remote.xsh`, `util.xsh`,
  `cli.xsh` fetch commands, `packages/*` source records):
  - the content-addressed cache;
  - local-mirror resolution;
  - `pm sources fetch` (the network step behind `make fetch`);
  - remove `default_repo_url` and `.env` reading;
  - tokenless local publish;
  - vendor `sudo-rs` crates;
  - delete the dead remote/local exports, the duplicated redirect and
    header code, and the fragile `source_vars` expansion;
  - fetch every upstream once and report dead URLs.
- **C. Seed and container** (`seed/`, `Dockerfile.package-tools`,
  `system/docker.xsh`, `bootstrap-llvm-seed.xsh`, recipes `xsh`, `xinit`,
  `llvm-toolchain`, `laputa-*`):
  - `seed.lock`;
  - `make seed`;
  - a package-tools image built from `.cache` with no network;
  - the xsh recipe packaged from the seed build;
  - in-tree xinit;
  - pass `XSH_PM_BUILD_ROOT` to recipes;
  - fix the update-xsh and `XSH_RELEASE` build-arg bugs, or replace them with
    `seed.lock`;
  - replace named volumes with paths that `make clean` owns.
- **D. PM build speed and identity** (`pm/plan.xsh`, `execute.xsh`,
  `store.xsh`, `fingerprint.xsh`, `build.xsh`):
  - the D2 executor identity, checked at build time against `plan.executor`;
  - `BUILD_EPOCH`;
  - hash once;
  - unpack once;
  - drop dead `XSH_PM_BUILD_CHROOT` and chroot leftovers;
  - measure plan and build time before and after on a fixed package set.

**Phase 2, integrator: first local bootstrap on macOS.**
1. `make clean`, then `fetch`, then `seed`, then `mirror`.
2. `make build STOP=pre-cmake` in arm64 Docker with `--network none`,
   publishing to the local mirror.
3. `root compose` a small root from the local mirror.
4. Run a rebuild with no changes and confirm it is a no-op that finishes in
   seconds.

**Phase 3, up to 4 lanes in parallel: cleanup and docs.**
- **Docs:**
  - one README, AGENTS.md and `docs/` set;
  - a co-development note on XSH;
  - fix stale PM.md, LAPUTA.md, INSTALLER.md and xinit docs.
- **Installer:**
  - aarch64 built from the local mirror;
  - delete the legacy x86_64 route that depends on the remote mirror (D5);
  - fix the serial console, the cmdline override and `forbidden_packages`
    enforcement.
- **Deduplication** in laputa scripts (GPT helpers, `env_value`, `run_argv`,
  `remove_tree`, the installer wrappers).
- **xsh changes the work surfaced,** such as primitives that would remove
  copy-paste.

**Phase 4, Linux amd64 host (later):**
- the x86_64 seed;
- cmake, linux and the rest of the world;
- kbuild speed;
- installer images and the QEMU proof.

## Decisions (settled 2026-10-03)

- **D1. Fetch once, then offline.**
  - `make fetch` is the only networked step: upstream sources, the LLVM
    seed, the Rust dist, vendored crates and the base image go into
    `.cache/`, each sha256-verified.
  - Everything after that runs with `--network none` against the local
    mirror.
  - Nothing ever contacts `laputa.17166969.xyz`.
- **D2. The seed xsh is built locally, never taken from a published
  release.**
  - `seed/seed.lock` pins an `../xsh` commit, and `make seed` builds it.
  - Artifact keys track that seed. Everyday xsh edits do not rebuild the
    distro; `make seed-bump` does, deliberately.
  - The PM identity covers only the modules that affect build outputs, and
    `BUILD_EPOCH` invalidates explicitly.
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

## Sequencing note

The XSH f-string migration (`{expr}` interpolation) is landing in `../xsh`
now. Its migration tool runs on the monorepo once Phase 0 lands, before the
Phase 1 lanes branch off. That keeps the f-string churn out of every lane's
diff.
