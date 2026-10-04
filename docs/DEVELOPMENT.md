# Laputa Development

This is the command reference for working in the monorepo. The root
`README.md` has the first-run sequence and the map of derived state;
`AGENTS.md` lists every make target.

Laputa builds on Linux aarch64 and x86_64 hosts and on Apple Silicon macOS.
`ARCH` (the seed and package target) defaults to the host's architecture, and
every container runs on the host's native Docker platform (`linux/arm64` or
`linux/amd64`). There is no cross-architecture build. The only supported
system profile is `qemu-dwl-foot`.

## XSH tools

XSH is a separate checkout at `XSH_ROOT` (default `../xsh`). The Makefile
takes host tools from `$XSH_ROOT/target/release/` when that build exists, and
on Linux otherwise from the static binaries `make host-xsh` writes to
`.out/host/<arch>/`. Override the directory with `XSH_BIN_DIR`. Every make
target sets `XSH_MODULE_PATH` to the checkout, which PM needs at runtime to
load recipes and spawn runners. Set it yourself when you run XSH directly:

```bash
export XSH_MODULE_PATH="$PWD"     # from the checkout root
export XSH_ROOT="$PWD/../xsh"
XSH_BIN_DIR="$PWD/.out/host/$(uname -m)"   # or "$XSH_ROOT/target/release"
export XSH_HOST="$XSH_BIN_DIR/xsh"
export XSHT="$XSH_BIN_DIR/xsht"
```

## Static check and tests

```bash
make check         # xsht check over the tree, plus shebang-only XSH scripts
make test-pm
make test-system   # tests/system, then tests/integration
make test-xinit
make test-linux    # the kernel recipe's Kbuild tests and linux-headers' headers_install tests
make test          # all four
```

`xsht-config.ini` sets `module_path` to this checkout, so `xsht` resolves
`system.*`, `seed.*`, and PM imports, including `use` imports inside profiles
loaded through `module.load`. It excludes the fixture trees under
`tests/*/fixtures/` and `mirror/`. `make check` also checks the XSH programs
installed under other names (installer and profile boot hooks, baselayout's
`getent`), which xsht's `*.xsh` scan does not find; it finds them by their
`#!/bin/xsh` shebang.

Narrow before widening: `xsht check` on the changed modules, then the focused
suite (`$XSHT test tests/pm/pm_plan.xsh`), then the Docker builds, and QEMU
last. Run one suite at a time. `make test-pm-docker` runs the whole PM suite
inside package-tools with the seed, offline; `make test-pm-native` runs it
against `XSH_ROOT`'s debug build with coverage.

`tests/integration/cross_consumer.xsh` imports PM and the profile modules
together. Check and run it on its own to tell PM-owned diagnostics from
profile-owned ones:

```bash
$XSHT check tests/integration/cross_consumer.xsh
$XSHT test --jobs 1 tests/integration/cross_consumer.xsh
```

## Seed and package-tools image

Containers run the local XSH seed, never a published release. `make fetch`
does the networked part once: every pinned source (the LLVM seed included)
into `.cache/sources/sha256/`, XSH's crates into `.cache/cargo/`, XSH's
`xsh-test` image, and the `laputa-host-tools` base (pinned Alpine plus apk
packages), saved to `.cache/images/`. Then, offline:

```bash
make seed        # static musl xsh/xshi/xsht + core.tar.xz under .out/seed/<arch>/, then the image
make seed-smoke  # the seed runs, plans, and passes a PM subset in the image with --network none
```

`make seed` builds `XSH_ROOT` with the release profile inside `xsh-test`,
reusing the cargo target `.out/xsh-target`, which `make host-xsh` shares.
`.out/seed/<arch>/manifest.json` records each product's sha256 and the XSH
commit and dirty flag. The `laputa-package-tools` image adds only the LLVM seed
from the source cache. Containers mount the seed at `/bin/{xsh,xshi,xsht}` and
`/usr/lib/xsh/core`, so an XSH or PM change rebuilds no image. Image tags are
content keys over each image's own inputs (`seed/images.xsh`).

## Local bootstrap

The bootstrap needs no remote mirror and contacts the network only in
`make fetch` (and `make host-xsh` on a fresh Linux host). There is no default
remote anywhere: PM talks to a mirror only when told to, and the make targets
point it at the loopback one.

```bash
make clean                     # all derived state; .cache/ survives
make fetch                     # networked: sources, crates, images; a no-op once cached
make seed                      # the XSH seed from XSH_ROOT, then package-tools
make mirror                    # in a second terminal: http://127.0.0.1:3000, data in .out/mirror
make build                     # offline build of every recipe in packages/
make publish                   # the same plan's artifacts into the mirror
make root PKGS="baselayout xsh xinit musl"
```

Stop the mirror with Ctrl-C when done.

- `make build` plans and builds in package-tools with `--network none`. The
  checkout, with the source cache, is mounted read-only. The artifact store
  `.out/artifacts/<arch>` is the build cache. Plans are offline, so every node
  reads `build`, and the executor reuses every artifact the store holds. An
  unchanged rebuild takes seconds, most of it planning.
- `PKGS="a b"` plans those packages' closures. `STOP=pre-cmake` runs
  `repo plan --all --without cmake --without linux`, a fast first signal on a
  new seed or toolchain. With neither, the build covers every package. The
  plan is `.out/world/<arch>/plan.json`.
- The kernel recipe keeps its Kbuild discovered-plan and archive-plan caches
  in `.out/cache/linux-kbuild`, mounted into world and profile containers.
  Every entry is checked against a fingerprint of the kernel source and
  `.config` before use.
- Containers have no network, so only host processes reach the mirror.
  `make publish` builds the same selection (a no-op when nothing changed),
  then `pm repo publish` uploads that plan's verified artifacts from the
  host.
- `make root` plans `PKGS` against the mirror on the host and requires every
  node to be an exact mirror artifact. It imports their closure into a fresh
  store under `.out/world/<arch>/root/`. Then, in an offline container, it
  composes the root, runs musl's loader over every dynamic ELF inside it, and
  runs the root's own `xsh`. `inspection.json`, `files.txt` and
  `generation.json` land beside that store.
- Artifact keys exclude the XSH runners and PM:
  - A new seed rebuilds only `xsh`.
  - A PM edit rebuilds only `laputa-pm`, which packages the PM tree.
  - A recipe `rel` bump rebuilds that package and its build dependents.
  - A kernel config change rebuilds only `linux`: packages that compile
    against kernel headers build-depend on `linux-headers`.
- Published objects are immutable and content-addressed: each is named by
  its artifact key (and proof key), and the index row is the only mutable
  pointer. A rebuilt `xsh` or `laputa-pm` keeps its `ver`/`rel`;
  `make publish` uploads it under new names and replaces only its index row.
  A row behind the mirror's `ver`/`rel` is refused. Reverting a change and
  publishing again moves the row back to the earlier, still-published key.
  `make root` imports the key each row names, which must be the key the
  checkout plans. See "Publication" in [PM](PM.md).

## Containers and file ownership

Builds use rootful Docker and containers run as root, so on Linux the files
containers write under `.out/` are owned by root. Two things keep that from
getting in the way:

- `make clean` and `make root` delete root-owned state from a container (in
  `xsh-test`, with the checkout mounted), so no `sudo` is needed.
- XSH's atomic writes keep the modes a plain write would get, so files a
  container writes (plans, receipts, store objects) stay readable by the
  host user. `make publish` reads the plan and the store from the host.

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
and `make publish` done. See [INSTALLER.md](../INSTALLER.md).

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

The generation's direct runtime roots are the profile's `package_roots`
(`profiles/qemu-dwl-foot.xsh`): `baselayout`, `xsh`, `laputa-pm`, `xinit`,
`mdevd`, `seatd`, `dwl-minimal`, and `foot-minimal`. Build-only tools such as
`llvm-toolchain`, `pkgconf`, `cmake`, `muon`, `samurai`, `m4`, `flex`,
`bison`, `wayland-dev`, `wayland-protocols`, and `pixman-dev` must be absent.
The profile lists them in `forbidden_packages`, and the build fails before
building anything if the generation's runtime closure contains one. It also
fails if any generation file provides or needs a `forbidden_sonames` entry.
