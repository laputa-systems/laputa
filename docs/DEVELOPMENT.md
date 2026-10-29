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

On macOS (Apple Silicon), build XSH's release binaries (`xsh`, `xshi`, `xsht`)
with `cargo build --release` in `XSH_ROOT`. The mirror and `make mirror-test`
run through `cargo`. Docker must run `linux/arm64` natively (for example
OrbStack).

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

### Package build authority

World containers and system-profile containers without `LAPUTA_REPO_URL` use
Docker's `--network none`. Recipes in those containers cannot reach host or
external IP endpoints through the container network. Loopback remains available.
Profiles with `LAPUTA_REPO_URL` retain Docker networking because PM fetches the
configured repository's index and artifacts inside the container. That path
also exposes networking to recipes and remains outside the offline boundary.
World fetch and mirror publication run on the host.

The trusted bootstrap closure includes the Docker daemon and Linux kernel,
the complete package-tools image, the mounted XSH seed, and the checkout.
The host-tools image contains Alpine packages installed by unpinned `apk`.
Its saved image is the bootstrap input; rebuilding the Dockerfile can change
those packages. The LLVM archive and the XSH seed are additional trusted
prebuilt inputs.

The checkout and seed mounts are read-only. Writable host mounts are `/output`,
`/artifacts`, and `/var/cache/laputa/linux-kbuild`. The container's image layer,
temporary directories, and Docker-provided device and pseudo-filesystems also
remain writable. Builds run as root with Docker's default capabilities.
The checkout mount exposes the whole checkout, including its cached inputs.
These containers do not enforce a per-package executable, library, environment,
or filesystem-read closure. The image environment and ambient tool paths inside
the container remain build inputs. The adapters request only explicit PM
environment settings. Docker client proxy configuration can still inject
additional environment values.

The opt-in closed cohort below qualifies a stricter invocation. Ordinary
package-tools builds retain the authority described above.

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
make root PKGS=baselayout   # import from the mirror, compose a root, check it runs
kill %1              # stop the mirror
```

PM has no default remote; these make targets use the loopback mirror.

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
- `PKGS` (space-separated names) plans those packages' closures. `STOP=pre-cmake` runs
  `repo plan --all --without cmake --without linux`, a fast first signal on a
  new seed or toolchain. With neither, the build covers every package. The
  plan is `.out/world/<arch>/plan.json`.
- The kernel recipe keeps its Kbuild discovered-plan and archive-plan caches
  in `.out/cache/linux-kbuild`, mounted into world and profile containers.
  By default, entries are checked against `.config`, reachable Kbuild or
  Makefile inputs, the active included files, the source architecture, and the
  cached plan before use. Explicit trust
  overrides can bypass fingerprint checks. `kbuild.plan_fingerprint` requires
  the source architecture to resolve those inputs.
  `kbuild.discover_plan_with_process_pool` takes a parsed configuration and
  shares it with every discovery worker. It returns a `KbuildDiscovery` with
  the plan and per-directory input records; `kbuild.discover_with_inputs`
  returns the same information for local discovery.
  `kbuild.plan_fingerprint_for_discovery` binds those records to a plan.
  Temporary pool files use `TMPDIR` when set and `/tmp` otherwise; an empty
  `TMPDIR` is rejected.
  The source tree's local scan-record cache uses format `linux-local-records-v4`;
  older records are discarded and rebuilt on the next discovery.
  The compile-flags cache binds parsed inputs and stored flags with format
  `linux-kbuild-compile-flags-v4`, and
  discovered-plan fingerprints use `linux-kbuild-plan-fingerprint-v12`.
  Archive-plan cache format `linux-archive-plan-cache-v4` binds the compiler
  path, prepared flags and source selections, EFI stub helper, and the report
  and summary.
  X86 EFI stub plans require `XSH_PM_RECIPE_DIR` to name the staged recipe;
  the copy task binds the helper digest and checks stripped objects for absolute
  relocations before running the stub copy.
  `kbuild.prepare_archive_analysis` returns a `PreparedArchivePlan` containing
  the plan, target and captured items consumed by
  `kbuild.plan_builtin_archives_with_analysis_workers`; worker inputs carry
  prepared items. Plan-only cache hits validate the summary without reading the
  full report.
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

### Closed cohort qualification

Run `bash tests/docker/closed_build.sh TOOL_SNAPSHOT [COMPILER_IMAGE]` on Linux
x86_64 with a local Docker daemon. `TOOL_SNAPSHOT` contains frozen
`bin/{xsh,xshi,xsht}` and `core/` directories. The default compiler image is
the locally available `xsh-test`. The test resolves its immutable image ID
before building, uses `--network none`, and never pulls an image.

`tests/docker/closed_build.Dockerfile` declares the compiler seed paths copied
into a scratch image: LLVM 23, musl headers and static libc, binutils, their
listed shared libraries, and the fixed Rust nightly toolchain. These are
trusted bootstrap exceptions, alongside the selected XSH runners, core
applets, PM modules, and cohort recipe sources. The compiler seed is not a
source bootstrap or a declaration of each tool as a PM artifact.
The `/usr/bin/clang` symlink preserves LLVM's canonical executable location,
so Clang resolves its builtin headers from `/usr/lib/llvm23/lib/clang/23`.

The driver also copies the host's selected `kache` and `mold` executables into
the declared seed at `/bin`. Rust compilation runs through `kache`. All cohort
musl links use `mold`. Kache's cache, runtime directory, and daemon socket stay
under the container's `/scratch`, with local-only caching and no host cache mount.
The run output reports both host tool versions and copied file sizes alongside
the compiler image identity. The image identity alone does not identify these
two host-selected seed inputs. The qualified kache 1.0.0 and mold 3.0.0 copies
add 45,455,072 file bytes
to the seed. This qualification does not measure their build-time cost.

The cohort runs through `pm.execute.build_plan` as your nonzero UID with no Linux
capabilities, no new privileges, and no network. A root caller uses UID 65534.
Docker makes the image root
read-only. Only `/scratch` and the fresh `/output` store are writable, apart
from the standard null, random, and terminal device interfaces. Source and
seed files are read-only. Only standard input, output, and error descriptors
enter the recipe. The Linux kernel, Docker daemon, Docker's default seccomp
policy, and its proc, sys, and device mounts remain trusted host interfaces.

The C recipe probes forbidden reads, writes, tools, libraries, environment,
privileges, and inherited descriptors once in each container. Three separate
PM recipes build a static C program, a static Rust program, and an XSH-generated
payload offline. PM runs each package's payload proof and publishes all three
artifacts. The driver builds twice into independent stores with different
checkout locations and ambient host environment values. It checks the poison
sentinels and matches receipts by package name. Each package's artifact key,
payload digest, and actual payload archive must match across both stores.
The output identifies the compiler seed and
executor provenance. The driver removes its disposable containers, image,
and working directories on exit.

This qualifies the bounded cohort invocation. Ordinary package-tools builds
still run recipes with the host executor's filesystem and environment.
Their build-root PATH prefix is not confinement. The cohort does not prove
production per-package isolation, a self-hosted compiler, resource isolation,
or protection against a compromised kernel or Docker daemon.

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
`profiles/qemu-maintained.xsh` is the long-lived profile and sets `development`
false. Its roots add Dropbear, nftables, and laputa-net. The other profiles set
`development` true and keep their current roots.

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

The `Makefile` is the reference; its comments describe each target. The ones
below carry behavior not stated elsewhere in this guide.

| Command | Does |
|---|---|
| `make host-xsh` | static musl `xsh`/`xshi`/`xsht` for the host arch in `.out/host/<arch>/`, built in XSH's `xsh-test` image with plain Docker; shares the seed's cargo target |
| `make check` | `xsht check` over the tree, plus XSH scripts without a `.xsh` name, found by their `#!/bin/xsh` shebang |
| `make lint` | `xsht lint` over PM, system, installer, and xinit (report only; never `--fix`) |
| `make fetch` | pinned sources into `.cache/sources/sha256/` (`pm sources fetch`), XSH's crates, the `xsh-test` image, and the saved host-tools base |
| `make fetch-mirror` | fetch the mirror's locked crates into the shared Cargo registry using the local `xsh-test` image |
| `make seed-asterinas-shell` | opt-in xshi integration seed; the pinned Asterinas backend builds its own seed |
| `make seed-smoke` | the seed in package-tools with `--network none`: offline plan plus a PM subset |
| `make mirror-build` | host `cargo build` for `mirror/`; needs a host Rust toolchain |
| `make update-checksums` | `pm repo update-checksums` for every recipe (networked) |
| `make store-gc` | remove store artifacts that neither the last world plan nor a profile plan names (between builds only) |
| `make verify` | the whole host proof from `make clean`, one step at a time, with logs and a timing table in `.out/verify/` |
| `make clean`, `make distclean` | see [derived state](#derived-state) |

Suites (including `test-pm-docker` and `test-pm-native`) are in [testing](TESTING.md), mirror targets in [mirror usage](../mirror/README.md)
and [mirror deployment](MIRROR-DEPLOYMENT.md), and `asterinas-*` targets in
[Asterinas](ASTERINAS.md).
