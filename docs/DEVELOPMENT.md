# Laputa Development

The root `Makefile` is the entry point for host tools, package builds, and VM
workflows. Tests are covered in [testing](TESTING.md).

Laputa builds on Linux aarch64 and x86_64 hosts and on Apple Silicon macOS.
`ARCH` (the seed and package target) defaults to the host's architecture, and
every container runs on the host's native Docker platform (`linux/arm64` or
`linux/amd64`). There is no cross-architecture build. The only supported
system profile is `qemu-dwl-foot`.

## Host requirements

On a Linux host (aarch64 or x86_64) you need only `git`, `make`, Docker
(the daemon running and usable by your user), and network access for the
fetch steps. You don't need a Rust toolchain or a pre-built XSH. `make
host-xsh` builds static XSH binaries and `make mirror` builds the mirror, both
in XSH's own build image.

The x86_64 compiler wrapper defaults to `-march=x86-64-v3`
(`packages/llvm-toolchain/PKGBUILD.xsh::default_march`). Native package proofs
need a CPU that supports that baseline.

On macOS (Apple Silicon), the developer path uses XSH's native release build
(`cargo build --release -j 4 -p xsh -p xshi -p xsht --bin xsh --bin xshi --bin xsht`
in `../xsh`) and runs the mirror and `make
mirror-test` through `cargo`. Docker must run `linux/arm64` natively (for
example OrbStack).

On Linux, builds use rootful Docker. Package builds give their outputs back to
you when they finish, and `make clean` deletes the cargo targets the XSH build
image leaves root-owned through a container.

VM host requirements belong to [QEMU](QEMU.md#host-requirements),
[installer](INSTALLER.md#entry-points), and [Asterinas](ASTERINAS.md).

## XSH tools

XSH is a separate checkout at `XSH_ROOT` (default `../xsh`). The Makefile
takes host tools from `$XSH_ROOT/target/release/` when that build exists, and
on Linux otherwise from the static binaries `make host-xsh` writes to
`.out/host/<arch>/`. Override the directory with `XSH_BIN_DIR`. The ordinary
Make targets use this checkout; the Asterinas targets build from the locked
XSH commit in their managed source snapshot. Make targets set
`XSH_MODULE_PATH` to this Laputa checkout, which PM needs to load recipes and
spawn runners. Set it yourself when you run XSH directly:

```bash
export XSH_MODULE_PATH="$PWD"     # from the checkout root
export XSH_ROOT="$PWD/../xsh"
XSH_BIN_DIR="$XSH_ROOT/target/release"
if [ "$(uname -s)" = Linux ] &&
   { [ ! -f "$XSH_BIN_DIR/xsh" ] ||
     [ ! -f "$XSH_BIN_DIR/xshi" ] ||
     [ ! -f "$XSH_BIN_DIR/xsht" ]; }; then
  XSH_BIN_DIR="$PWD/.out/host/$(uname -m | sed 's/^arm64$/aarch64/; s/^amd64$/x86_64/')"
fi
export XSH_HOST="$XSH_BIN_DIR/xsh"
export XSHT="$XSH_BIN_DIR/xsht"
export PATH="$XSH_BIN_DIR:$PATH"
```

## Seed and package-tools image

Containers run the local XSH seed, never a published release. `make fetch`
does the networked part once: every pinned source (the LLVM seed included)
into `.cache/sources/sha256/`, XSH's crates into `.cache/cargo/`, XSH's
`xsh-test` image, and the `laputa-host-tools` base (pinned Alpine plus apk
packages), saved to `.cache/images/`. Then, offline:

```bash
make seed        # static musl xsh/xshi/xsht + core.tar.xz under .out/seed/<arch>/, then the image
make seed-asterinas-shell # opt-in xshi integration variant; the pinned backend builds its own seed
make seed-smoke  # the seed runs, plans, and passes a PM subset in the image with --network none
```

`make seed` builds `XSH_ROOT` with the release profile inside `xsh-test`,
reusing the cargo target `.out/xsh-target`, which `make host-xsh` shares.
`.out/seed/<arch>/manifest.json` records each product's sha256 and the XSH
commit and dirty flag. The `laputa-package-tools` image adds only the LLVM seed
from the source cache. Containers mount the seed at `/bin/{xsh,xshi,xsht}` and
`/usr/lib/xsh/core`, so an XSH or PM change rebuilds no image. Image tags are
content keys over each image's own inputs (`seed/images.xsh`).

The LLVM seed stays prebuilt. Its pin belongs to
`packages/llvm-toolchain/PKGBUILD.xsh`. The `xsh` recipe packages the local
seed rather than compiling another interpreter in the package world.

## Local bootstrap

```sh
git clone https://github.com/laputa-systems/laputa.git
git clone https://github.com/laputa-systems/xsh.git    # beside laputa: ../xsh
cd laputa
make host-xsh        # networked once: xsh-test image, XSH crates; then static xsh/xshi/xsht in .out/host/<arch>/
make fetch           # the networked step: every pinned source, the crates, the host-tools base image
make seed            # offline: the XSH seed in .out/seed/<arch>/, then the package-tools image
make mirror &        # http://127.0.0.1:3000, data in .out/mirror (the first run builds the mirror)
make build           # offline: every package, in Docker with --network none
make publish         # the same plan's artifacts into the local mirror
make root PKGS="baselayout xsh xinit musl"   # import from the mirror, compose a root, check it runs
kill %1              # stop the mirror
```

`ARCH` defaults to the host's architecture, and the package build runs
natively in Docker. `make build STOP=pre-cmake` builds only the packages that
need neither cmake nor linux, and `PKGS="a b"` builds those packages and their
dependencies. A rebuild with nothing changed reuses every artifact.

Stop the mirror with Ctrl-C if it runs in a separate terminal. PM has no
default remote; these make targets use the loopback mirror.

- `make build` plans and builds in package-tools with `--network none`. The
  checkout, with the source cache, is mounted read-only. The artifact store
  `.out/artifacts/<arch>` is the build cache. Plans are offline, so every node
  reads `build`, and the executor reuses every artifact the store holds. An
  unchanged rebuild reuses those artifacts.
- `JOBS` (default 4) bounds how many packages build at once. A package starts
  as soon as the packages it needs are in the store, not when a whole plan
  level finishes. Each one builds in its own child process with its log in
  `.out/world/<arch>/logs/<package>.log`, so the console shows one line per
  start and finish. A failure stops the other builds and prints the failing
  package, its log path, and the log's tail. The build ends with its slowest
  packages.
- `PKGS="a b"` plans those packages' closures. `STOP=pre-cmake` runs
  `repo plan --all --without cmake --without linux`, a fast first signal on a
  new seed or toolchain. With neither, the build covers every package. The
  plan is `.out/world/<arch>/plan.json`.
- The kernel recipe keeps its Kbuild discovered-plan and archive-plan caches
  in `.out/cache/linux-kbuild`, mounted into world and profile containers.
  Every entry is checked against a fingerprint of the kernel source and
  `.config` before use.
- Containers have no network, so only host processes reach the mirror.
  Host planning, importing, publishing, and composition call typed PM operations
  in the same process under a scoped `XSH_PM_REPO` value.
  `make publish` builds the same selection (a no-op when nothing changed),
  then `pm repo publish` uploads that plan's verified artifacts from the
  host.
- `make root` plans `PKGS` against the mirror on the host and requires every
  node to be an exact mirror artifact. It imports their closure into a fresh
  store under `.out/world/<arch>/root/`. Then, in an offline container, it
  composes the root, runs musl's loader over every dynamic ELF inside it, and
  runs the root's own `xsh`. `inspection.json`, `files.txt` and
  `generation.json` land beside that store.

See [artifact identity](PM.md#identity-store-and-snapshots) for rebuild rules
and [publication](PM.md#publication) for immutable objects and index updates.

## Containers and file ownership

Builds use rootful Docker and containers run as root (recipes build as root
and `make root` chroots). Package-tools containers start through
`seed/container_entry.xsh`, which runs the command, then gives the writable
mounts (`/output`, the store at `/artifacts`, and the Kbuild cache) to the host
user that started the build. So the world, the store, and profile outputs
under `.out/` and `target/` belong to you after every run, failed or not.

The cargo builds in `xsh-test` (`make host-xsh`, `make seed`, the mirror) still
leave root-owned target directories, so `make clean` and `make root` delete
derived state from a container on Linux and no `sudo` is needed.

On macOS, Docker maps container writes to the host user.

## The qemu-dwl-foot profile

```bash
make profile-plan
make profile-build
make profile-test
make profile-boot
make profile-clean
```

The profile CLI (`laputa.xsh`) builds its artifacts into the same store in
native Docker and boots the result in QEMU on the host. It needs `make seed`
but not the mirror. [QEMU proof](QEMU.md) covers its outputs, host
requirements, and the proof contract.

## Installer

`make installer-image` and `make installer-qemu-test` take `ARCH` and import
their package roots from the local mirror, so `make mirror` must be running
and `make publish` done. See [installer](INSTALLER.md).

Installer host validation failures use XSH's standard `validation` error
kind; child failures retain the child's exit code.

## Verify the artifact store

The profile CLI has no store command. Run the PM verifier inside
package-tools with the seed mounted:

```bash
ARCH=x86_64 PLATFORM=linux/amd64     # or ARCH=aarch64 PLATFORM=linux/arm64
docker run --rm --network none --platform "$PLATFORM" \
  --mount type=bind,src="$PWD/.out/artifacts/$ARCH",dst=/artifacts,readonly \
  --mount type=bind,src="$PWD",dst=/src/laputa,readonly \
  --mount type=bind,src="$PWD/.out/seed/$ARCH/xsh",dst=/bin/xsh,readonly \
  --mount type=bind,src="$PWD/.out/seed/$ARCH/core",dst=/usr/lib/xsh/core,readonly \
  --workdir /src/laputa \
  --env XSH_MODULE_PATH=/src/laputa \
  "$(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=laputa-package-tools:$ARCH-*" | head -n 1)" \
  /bin/xsh /src/laputa/pm.xsh -- store verify --store /artifacts
```

Every artifact must verify. `pm store verify` re-hashes every object and
mutates nothing.

## Inspect a generated system

Mount the profile output at `/profile` the same way and run
`pm root inspect` on its generation:

```bash
docker run --rm --network none --platform "$PLATFORM" \
  --mount type=bind,src="$PWD/target/laputa/qemu-dwl-foot",dst=/profile,readonly \
  --mount type=bind,src="$PWD",dst=/src/laputa,readonly \
  --mount type=bind,src="$PWD/.out/seed/$ARCH/xsh",dst=/bin/xsh,readonly \
  --mount type=bind,src="$PWD/.out/seed/$ARCH/core",dst=/usr/lib/xsh/core,readonly \
  --workdir /src/laputa \
  --env XSH_MODULE_PATH=/src/laputa \
  "$(docker image ls --format '{{.Repository}}:{{.Tag}}' --filter "reference=laputa-package-tools:$ARCH-*" | head -n 1)" \
  /bin/xsh /src/laputa/pm.xsh -- root inspect /profile/current/generation.json
```

`profiles/qemu-dwl-foot.xsh` owns `package_roots`, `forbidden_packages`, and
`forbidden_sonames`. The profile build checks the runtime closure against
these exclusions before execution and checks sonames in the composed files.

## Derived state

| Path | Holds | Removed by |
|---|---|---|
| `.cache/sources/sha256/` | fetched upstream sources, by digest | `make distclean` |
| `.cache/cargo/`, `.cache/images/` | XSH and mirror crates, the saved host-tools base image | `make distclean` |
| `.cache/asterinas/` | pinned Asterinas and XSH source caches | `make asterinas-clean` |
| `.out/host/<arch>/` | host `xsh`/`xshi`/`xsht` and `laputa-mirror` (Linux) | `make clean` |
| `.out/xsh-target/`, `.out/mirror-target/` | incremental cargo targets for the seed and host tools | `make clean` |
| `.out/seed/<arch>/` | the XSH seed and its manifest | `make clean` |
| `.out/artifacts/<arch>/` | the PM artifact store, which is the build cache | `make clean` |
| `.out/world/<arch>/` | the last plan and the `make root` tree | `make clean` |
| `.out/cache/linux-kbuild/` | the kernel recipe's Kbuild plan cache | `make clean` |
| `.out/asterinas-firecracker/` | immutable Asterinas + Laputa bundles, writable run disks, and logs | `make asterinas-clean` |
| `.out/mirror/` | local mirror data | `make clean` |
| `target/` | profile (`target/laputa/`) and installer outputs | `make clean` |

`make clean` removes all derived state, including the `laputa-*` Docker
images. `make distclean` also removes `.cache/`, after which `make fetch` has
to download everything again. XSH's `xsh-test` image belongs to XSH, and both
targets leave it in place.

## Make targets

| Command | Does |
|---|---|
| `make host-xsh` | static musl `xsh`/`xshi`/`xsht` for the host arch in `.out/host/<arch>/`, built in XSH's `xsh-test` image with plain Docker (no host XSH or Rust); shares the seed's cargo target |
| `make check` | `xsht check` over the tree (`xsht-config.ini` owns module path and excludes), plus XSH scripts without a `.xsh` name (boot hooks, `getent`), found by their `#!/bin/xsh` shebang |
| `make lint` | `xsht lint` over PM, system, installer, and xinit (report only; never `--fix`) |
| `make fetch [ARCH=x86_64]` | fetches pinned upstream sources into `.cache/sources/sha256/` (`pm sources fetch`), XSH's crates, the `xsh-test` image, and the saved host-tools base for offline builds |
| `make seed [ARCH=…]` | offline: static musl `xsh`/`xshi`/`xsht` and `core.tar.xz` from `XSH_ROOT` into `.out/seed/<arch>/` with a manifest, then the package-tools image |
| `make seed-asterinas-shell [ARCH=…]` | offline: opt-in xshi integration variant; the pinned backend builds its own seed |
| `make build [PKGS="a b" \| STOP=pre-cmake]`, `make plan` | PM plan and build in package-tools with `--network none` into `.out/artifacts/<arch>` (the build cache); `STOP=pre-cmake` is `repo plan --all --without cmake --without linux` |
| `make mirror`, `make publish [PKGS=… \| STOP=…]` | the loopback local mirror (foreground; on Linux built by `make host-mirror` in `xsh-test`, elsewhere run through cargo); publish builds the selection, then uploads it from the host |
| `make root PKGS="…"` | import PKGS from the mirror on the host, compose the root offline in a container, check its ELF files load and its xsh runs |
| `make seed-smoke`, `make test-pm-docker` | the seed in package-tools with `--network none`: offline plan plus a PM subset, or the full PM suite |
| `make test` | the `test-pm`, `test-system`, `test-xinit`, and `test-linux` native suites |
| `make test-linux` | the kernel recipe's Kbuild tests, each with a test-owned plan cache, and linux-headers' `headers_install` tests |
| `make test-pm-native` | the PM suite against XSH_ROOT's debug build (`make xsh-native`), with coverage under `target/coverage/` |
| `make update-checksums` | `pm repo update-checksums` for every recipe (networked) |
| `make mirror-build` | host `cargo build` for `mirror/`; requires a host Rust toolchain |
| `make mirror-test` | mirror tests plus fake-command deployment checks; on Linux Cargo runs offline in `xsh-test` |
| `make preflight-mirror`, `make deploy-mirror` | read-only deployment checks, then build and converge the production mirror over SSH and Cloudflare `cf` |
| `make profile-{plan,build,test,boot,clean}` | the typed profile CLI on the host: builds in native Docker for the host arch, boots QEMU with HVF (macOS) or KVM (Linux) |
| `make installer-image`, `make installer-qemu-test [ARCH=…]` | installer ISO and its QEMU install-and-boot proof; roots come from the local mirror, so `make mirror` and `make publish` come first |
| `make installer-qemu-manual` | aarch64-only interactive installer boot; set `XSH_MODULE_PATH` to the checkout root |
| `make asterinas-preflight`, `make asterinas-fetch`, `make asterinas-build` | checks host capabilities, fetches locked source/tool inputs, and builds an immutable Asterinas + Laputa bundle |
| `make asterinas-test [XSH_TEST=tests/xsh/<module>.xsh]` | boots the PM-built ext2 root under Asterinas/Firecracker and checks xinit, XSH, and guest filesystem/process behavior; optionally runs one pinned XSH test module |
| `make asterinas-boot` | boots the PM-built Laputa root and connects an interactive xshi session to Firecracker's serial console |
| `make asterinas-clean` | removes all checkout build outputs, fetched caches, and pinned builder images for a cold Asterinas rebuild |
| `make asterinas-setup` | builds the pinned Asterinas PVH kernel and boots a small KVM smoke guest |
| `make store-gc` | remove store artifacts that neither the last world plan nor a profile plan names (between builds only) |
| `make verify` | the whole host proof from `make clean`, one step at a time, with logs and a timing table in `.out/verify/` |
| `make clean` | remove all derived state (`.out/`, `target/`, mirror frontend outputs, `laputa-*` images), through a container on Linux because rootful Docker leaves root-owned files; `make distclean` also removes `.cache/` |
