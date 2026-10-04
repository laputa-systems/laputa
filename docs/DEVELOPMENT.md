# Laputa Core Infrastructure Development

This is the command reference for the completed typed core-infrastructure workflow. All package build, proof, root-composition, and disk-image commands execute in native `linux/arm64` Docker containers; QEMU runs on an Apple Silicon macOS host with Homebrew QEMU and HVF. The only supported system profile is `qemu-dwl-foot`.

PM, recipes (`packages/`), and the profile modules (`system/`) live in this
monorepo; XSH is a sibling checkout at `XSH_ROOT` (default `../xsh`). Set the
roots when they differ:

```bash
export XSH_ROOT="$HOME/d/laputa-systems/xsh"
export LAPUTA_ROOT="$HOME/d/laputa-systems/laputa"
export XSH_MODULE_PATH="$LAPUTA_ROOT"
export XSH_HOST="$XSH_ROOT/target/release/xsh"
export XSHT="$XSH_ROOT/target/release/xsht"
```

Build the XSH tools before invoking these commands if they do not yet exist. Do not use an installed XSH binary in place of the checked-out runner.

## Static check

```bash
cd "$LAPUTA_ROOT"
XSH_MODULE_PATH="$PWD" "$XSHT" check \
  laputa.xsh \
  system/*.xsh \
  profiles/*.xsh \
  guest/*.xsh \
  tests/system/*.xsh
```

`xsht check` validates dynamic boundaries by default; the `--strict` option
has been removed. `system/container_build.xsh` statically imports PM generation
modules, so its check also requires the checked-out PM graph to pass the current
language contracts.

Run the native test suite from the checkout root:

```bash
make test-system
```

`xsht-config.ini` sets `module_path` to this checkout, so `xsht test` resolves
`system.*` and PM imports, including `use` imports inside profiles loaded
through `module.load`. It also excludes `tests/system/fixtures/`: the standalone
`container-local-staging.xsh` script requires the Linux container's
`/src/laputa` and `/output` mounts and must run through container verification
instead of the host native-test gate.

The combined PM/Laputa import test uses the PM source graph. Check and run it
separately to distinguish package-owned diagnostics from Laputa-owned modules:

```bash
XSH_MODULE_PATH="$PWD" "$XSHT" check tests/integration/cross_consumer.xsh
XSH_MODULE_PATH="$PWD" "$XSHT" test --jobs 1 tests/integration/cross_consumer.xsh
```

## PM test

```bash
cd "$LAPUTA_ROOT"
make test-pm
```

## Seed and package-tools image

Containers run the local XSH seed, never a published release. `make fetch`
does the networked part once: XSH's crates into `.cache/cargo`, XSH's
`xsh-test` image, and the `laputa-host-tools` base (pinned Alpine plus apk),
saved to `.cache/images/`. Then, offline:

```bash
cd "$LAPUTA_ROOT"
make seed        # static musl xsh/xshi/xsht + core.tar.xz under .out/seed/aarch64, then the image
make seed-smoke  # the seed runs, plans, and passes PM suites in the image with --network none
```

`make seed` builds `XSH_ROOT` with the release profile inside `xsh-test`, as
XSH's Linux test path does, reusing the cargo target dir `.out/xsh-target`.
`.out/seed/<arch>/manifest.json` records each product's sha256 and the XSH
commit and dirty flag. The `laputa-package-tools` image adds only the LLVM seed
from the source cache; the Docker adapter mounts the seed at
`/bin/{xsh,xshi,xsht}` and `/usr/lib/xsh/core`, so an XSH or PM change rebuilds
no image. Image tags are content keys over each image's own inputs
(`seed/images.xsh`).

## Local bootstrap

The bootstrap needs no remote mirror and contacts the network only in
`make fetch`. A Linux host without a Rust toolchain first runs `make host-xsh`
(the sequence is in the root `README.md`). From a clean checkout on Apple
Silicon (OrbStack, `linux/arm64`):

```bash
cd "$LAPUTA_ROOT"
make clean                     # all derived state; .cache/ survives
make fetch                     # networked: sources, crates, images; a no-op once cached
make seed                      # the XSH seed from XSH_ROOT, then package-tools
make mirror                    # in a second terminal: http://127.0.0.1:3000, data in .out/mirror
make build STOP=pre-cmake      # offline build of every package that needs neither cmake nor linux
make publish STOP=pre-cmake    # the same plan's artifacts into the mirror
make root PKGS="baselayout xsh xinit musl m4 less pkgconf libxkbcommon pixman"
```

Stop the mirror with Ctrl-C when done.

- `make build` plans and builds in package-tools with `--network none`. The
  checkout, with the source cache, is mounted read-only. The artifact store
  `.out/artifacts/<arch>` is the build cache. Plans are offline, so every node
  reads `build`, and the executor reuses every artifact the store holds. An
  unchanged rebuild takes about 10 s, most of it planning.
- `PKGS="a b"` plans those packages' closures. `STOP=pre-cmake` runs
  `repo plan --all --without cmake --without linux`. With neither, the build
  covers every package. The plan is `.out/world/<arch>/plan.json`.
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
- Published objects are immutable and content-addressed: each is named by
  its artifact key (and proof key), and the index row is the only mutable
  pointer. A rebuilt `xsh` or `laputa-pm` keeps its `ver`/`rel`;
  `make publish` uploads it under new names and replaces only its index row.
  A row behind the mirror's `ver`/`rel` is refused. Reverting a change and
  publishing again moves the row back to the earlier, still-published key.
  `make root` imports the key each row names, which must be the key the
  checkout plans. See "Publication" in [PM](PM.md).

## Profile plan

```bash
cd "$LAPUTA_ROOT"
"$XSH_HOST" laputa.xsh -- plan qemu-dwl-foot
```

The plan writes `target/laputa/qemu-dwl-foot/build-plan.json`. Running it twice from clean profile output must produce byte-identical plan bytes.

## Profile build

```bash
cd "$LAPUTA_ROOT"
"$XSH_HOST" laputa.xsh -- build qemu-dwl-foot --jobs 4
```

The build resolves or imports exact package artifacts, composes an immutable generation, and atomically publishes one complete system bundle under `builds/<system-key>`. `current` is atomically switched to that bundle only after its plan, generation manifest, kernel, root filesystem, and disk image are all verified. A warm run reuses matching artifacts and preserves plan digest, generation digest, and image hash.

## Profile test

```bash
cd "$LAPUTA_ROOT"
"$XSH_HOST" laputa.xsh -- test qemu-dwl-foot
```

`test` first produces or refreshes `current`, then uses QMP to inject deterministic input into the real foot terminal and validates console markers. Success is exactly `laputa test qemu-dwl-foot: ok`. The active bundle contains `disk.img`, `rootfs.ext4`, `vmlinuz`, `generation.json`, and `build-plan.json`; the profile root contains `console.log`, `qemu.log`, and `screenshot.ppm`. A kernel panic marker is a test failure.

## Interactive boot

```bash
cd "$LAPUTA_ROOT"
"$XSH_HOST" laputa.xsh -- boot qemu-dwl-foot
```

This opens QEMU's Cocoa display and launches the normal dwl and foot session. It is an interactive diagnostic path, not the acceptance test.

## Clean profile outputs

```bash
cd "$LAPUTA_ROOT"
"$XSH_HOST" laputa.xsh -- clean qemu-dwl-foot
```

This removes only `target/laputa/qemu-dwl-foot`; it must not remove the immutable package-artifact store at `.out/artifacts/aarch64`. `make clean` removes all derived state, the store included; `make distclean` also removes `.cache/`.

## Verify the artifact store

The final public Laputa CLI intentionally has no store command. Invoke the PM verifier inside the Docker runner:

```bash
cd "$LAPUTA_ROOT"
docker run --rm --platform linux/arm64 \
  --mount type=bind,src="$LAPUTA_ROOT/.out/artifacts/aarch64",dst=/artifacts,readonly \
  --mount type=bind,src="$LAPUTA_ROOT",dst=/src/laputa,readonly \
  --mount type=bind,src="$LAPUTA_ROOT/.out/seed/aarch64/xsh",dst=/bin/xsh,readonly \
  --mount type=bind,src="$LAPUTA_ROOT/.out/seed/aarch64/core",dst=/usr/lib/xsh/core,readonly \
  --workdir /src/laputa \
  --env XSH_MODULE_PATH=/src/laputa \
  "$(docker image ls --format '{{.Repository}}:{{.Tag}}' laputa-package-tools | head -n 1)" \
  /bin/xsh /src/laputa/pm.xsh -- store verify --store /artifacts
```

Every artifact must verify. This is `pm store verify --store STORE` running in the Docker build environment; it does not publish or mutate the repository.

## Inspect a generated system

```bash
cd "$LAPUTA_ROOT"
docker run --rm --platform linux/arm64 \
  --mount type=bind,src="$LAPUTA_ROOT/.out/artifacts/aarch64",dst=/artifacts,readonly \
  --mount type=bind,src="$PWD/target/laputa/qemu-dwl-foot",dst=/profile,readonly \
  --mount type=bind,src="$LAPUTA_ROOT",dst=/src/laputa,readonly \
  --mount type=bind,src="$LAPUTA_ROOT/.out/seed/aarch64/xsh",dst=/bin/xsh,readonly \
  --mount type=bind,src="$LAPUTA_ROOT/.out/seed/aarch64/core",dst=/usr/lib/xsh/core,readonly \
  --workdir /src/laputa \
  --env XSH_MODULE_PATH=/src/laputa \
  "$(docker image ls --format '{{.Repository}}:{{.Tag}}' laputa-package-tools | head -n 1)" \
  /bin/xsh /src/laputa/pm.xsh -- generation inspect /profile/current/generation.json
```

The generation's direct runtime roots must be `baselayout`, `xsh`, `laputa-pm`, `xinit`, `mdevd`, `seatd`, `dwl-minimal`, and `foot-minimal`. Build-only tools must be absent unless independently runtime-required: `llvm-toolchain`, `pkgconf`, `cmake`, `muon`, `samurai`, `m4`, `flex`, `bison`, `wayland-dev`, `wayland-protocols`, and `pixman-dev`.

## Scope

The core profile is aarch64-only. Browser automation, real hardware, IPv6,
and Wi-Fi are not acceptance targets for this profile. Installer workflows are
kept separate from the typed profile CLI; see the installer entrypoints in the
root `Makefile` when working on that product.

For QEMU requirements, output artifacts, QMP proof semantics, and failure
marker diagnosis, see [QEMU proof](QEMU.md).
