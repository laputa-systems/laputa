# Laputa Core Infrastructure Development

This is the command reference for the completed typed core-infrastructure workflow. All package build, proof, root-composition, and disk-image commands execute in native `linux/arm64` Docker containers; QEMU runs on an Apple Silicon macOS host with Homebrew QEMU and HVF. The only supported system profile is `qemu-dwl-foot`.

Set the checkout roots when they differ from the standard sibling layout:

```bash
export XSH_SOURCE_ROOT="$HOME/d/laputa-systems/xsh"
export LAPUTA_PACKAGES_ROOT="$HOME/d/laputa-systems/packages"
export XSH_HOST="$XSH_SOURCE_ROOT/target/debug/xsh"
export XSHT="$XSH_SOURCE_ROOT/target/debug/xsht"
```

Build the local debug XSH tools before invoking these commands if they do not yet exist. Do not use an installed XSH binary in place of the checked-out runner.

## Static check

```bash
cd "$HOME/d/laputa-systems/laputa"
XSH_MODULE_PATH="$PWD:$LAPUTA_PACKAGES_ROOT" "$XSHT" check --strict \
  laputa.xsh \
  laputa/*.xsh \
  profiles/*.xsh \
  guest/*.xsh \
  tests/xsh/*.xsh
```

## PM test

```bash
cd "$LAPUTA_PACKAGES_ROOT"
make test
```

## Profile plan

```bash
cd "$HOME/d/laputa-systems/laputa"
"$XSH_HOST" laputa.xsh -- plan qemu-dwl-foot
```

The plan writes `target/laputa/qemu-dwl-foot/build-plan.json`. Running it twice from clean profile output must produce byte-identical plan bytes.

## Profile build

```bash
cd "$HOME/d/laputa-systems/laputa"
"$XSH_HOST" laputa.xsh -- build qemu-dwl-foot --jobs 4
```

The build resolves or imports exact package artifacts, composes an immutable generation, and atomically writes the profile image. A warm run reuses matching artifacts and preserves plan digest, generation digest, and image hash.

## Profile test

```bash
cd "$HOME/d/laputa-systems/laputa"
"$XSH_HOST" laputa.xsh -- test qemu-dwl-foot
```

Success is exactly `laputa test qemu-dwl-foot: ok`. The test uses QMP to inject deterministic input into the real foot terminal and validates console markers. Its output directory contains `console.log`, `qemu.log`, `screenshot.ppm`, `disk.img`, `vmlinuz`, and `generation.json`. A kernel panic marker is a test failure.

## Interactive boot

```bash
cd "$HOME/d/laputa-systems/laputa"
"$XSH_HOST" laputa.xsh -- boot qemu-dwl-foot
```

This opens QEMU's Cocoa display and launches the normal dwl and foot session. It is an interactive diagnostic path, not the acceptance test.

## Clean profile outputs

```bash
cd "$HOME/d/laputa-systems/laputa"
"$XSH_HOST" laputa.xsh -- clean qemu-dwl-foot
```

This removes only `target/laputa/qemu-dwl-foot`; it must not remove the immutable package-artifact store.

## Verify the artifact store

The final public Laputa CLI intentionally has no store command. Invoke the PM verifier inside the Docker runner:

```bash
cd "$HOME/d/laputa-systems/laputa"
docker run --rm --platform linux/arm64 \
  --mount type=volume,src=laputa-artifacts-aarch64-v1,dst=/artifacts,readonly \
  --mount type=bind,src="$LAPUTA_PACKAGES_ROOT",dst=/src/packages,readonly \
  --workdir /src/packages \
  --env XSH_MODULE_PATH=/src/packages \
  laputa-package-tools \
  /bin/xsh /src/packages/pm.xsh -- store verify --store /artifacts
```

Every artifact must verify. This is `pm store verify --store STORE` running in the Docker build environment; it does not publish or mutate the repository.

## Inspect a root generation

```bash
cd "$HOME/d/laputa-systems/laputa"
docker run --rm --platform linux/arm64 \
  --mount type=volume,src=laputa-artifacts-aarch64-v1,dst=/artifacts,readonly \
  --mount type=bind,src="$PWD/target/laputa/qemu-dwl-foot",dst=/profile,readonly \
  --mount type=bind,src="$LAPUTA_PACKAGES_ROOT",dst=/src/packages,readonly \
  --workdir /src/packages \
  --env XSH_MODULE_PATH=/src/packages \
  laputa-package-tools \
  /bin/xsh /src/packages/pm.xsh -- root inspect /profile/generation.json
```

The generation's direct runtime roots must be `baselayout`, `xsh`, `laputa-pm`, `xinit`, `mdevd`, `seatd`, `dwl-minimal`, and `foot-minimal`. Build-only tools must be absent unless independently runtime-required: `llvm-toolchain`, `pkgconf`, `cmake`, `muon`, `samurai`, `m4`, `flex`, `bison`, `wayland-dev`, `wayland-protocols`, and `pixman-dev`.

## Scope

The core profile is aarch64-only. Browser automation, real hardware, IPv6,
and Wi-Fi are not acceptance targets for this profile. Installer workflows are
kept separate from the typed profile CLI; see the installer entrypoints in the
root `Makefile` when working on that product.

For QEMU requirements, output artifacts, QMP proof semantics, and failure
marker diagnosis, see [QEMU proof](QEMU.md).
