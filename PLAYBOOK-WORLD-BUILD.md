# World Build Playbook

A world build plans the package repo, builds packages in dependency tranches,
stages a local repository under `~/.cache/laputa/world-<hash>`, and can upload
that staged repository to the public package repo.

## Entry Points

| Target | Where | Arch | Mechanism |
|---|---|---|---|
| `make world-build` | macOS or any Docker host | `aarch64` by default | Docker + QEMU/binfmt |
| `make world-build-aarch64` | `threadripper`/amd64 | `aarch64` | native cross-compilation |
| `make world-build-amd64` | amd64 host as root | `x86_64` | native chroot |

`make world-build` is the normal macOS path. It ensures the local package-tools
image exists, builds a local Linux-musl `xsh-multicall` from the sibling `xsh`
checkout, mounts that as the world-build `xsh`, and mounts local `core/`
applets. The published xsh inside the Docker image is bootstrap state.

`make world-build-aarch64` is the fast native-cross path for amd64 Linux hosts.
It sets `XSH_PM_NATIVE_CROSS=1`, using an x86_64 build root for host tools and
an aarch64 target root for package artifacts.

`make world-build-amd64` is a native x86_64 chroot build and requires root.
On Threadripper, it runs the checked-out debug XSH from the sibling `xsh`
checkout through the `host-xsh-multicall` links created by the Makefile. It
also requires the configured mirror to contain the x86_64 bootstrap packages.
If the mirror has only aarch64 entries, seed the x86_64 bootstrap repository
before resuming the world; the musl/LLVM bootstrap dependency cycle cannot be
resolved by an ordinary package-test against that incomplete mirror.

## Common Commands

```bash
# Build/resume the default aarch64 world.
make world-build

# Limit package parallelism. The macOS Docker default is already 4.
make world-build WORLD_JOBS=2

# Stop after a tranche. Tranches are zero-indexed in PM output.
make world-build WORLD_TO_TRANCHE=3

# Build a complete world and upload it.
make world-build WORLD_UPLOAD=1

# Resume the native x86_64 world on Threadripper.
make world-build-amd64

# Use another package checkout.
make world-build LAPUTA_PACKAGES_ROOT=$HOME/dev/packages

# Use another package-tools image.
make world-build PACKAGE_TOOLS_IMAGE=laputa-bootstrapped-build-essential-native:latest
```

Individual package proofs:

```bash
make package-test PKGNAME=<name>
make package-publish PKGNAME=<name>
```

Common package shortcuts include `pkgconf-test`, `cmake-test`, `samurai-test`,
`dropbear-test`, `tmux-test`, `linux-pam-test`, `sudo-rs-test`,
`iptables-test`, `tailscale-test`, and `less-test`.

Kernel iteration has focused `linux-amd64-*` targets for config, source prep,
compile, link, package, object, and cache proofs.

## World State

`pm world-plan` loads packages from the package repo, computes a stable world
cache path from the package set and arch, then records a content fingerprint
from selected `PKGBUILD.xsh` files. The cache lives at:

```text
~/.cache/laputa/world-<hash>/
  index.json                 # staged remote index for built packages
  packages/<arch>/<pkg>/     # staged package tarballs
  metadata/<arch>/<pkg>/     # metadata sidecars
  .world/                    # target/build roots and state
  .work/                     # per-package build dirs
  .out/                      # download/cache output
```

The cache path is stable for a package set and arch. If package inputs change,
PM reconciles the existing state with the new fingerprint and preserves
compatible built package IDs.

Packages build in dependency levels called tranches. PM builds packages within a
tranche in parallel up to `--jobs`. `WORLD_TO_TRANCHE=N` stops after tranche `N`
and leaves the stage resumable. Re-run with the same or higher tranche to
continue.

## Upload

`WORLD_UPLOAD=1` appends `--upload` to the `world-plan` invocation. PM verifies
the world stage is complete, uploads package tarballs and metadata sidecars, and
writes the remote `index.json`. Files larger than the normal upload threshold
use PM's chunked upload path.

The token comes from `.env` as `LAPUTA_TOKEN=<token>`; PM can also use its normal
auth sources.

Important: `WORLD_UPLOAD=1` requires a complete world. If the build was stopped
with `WORLD_TO_TRANCHE`, PM will fail the upload with:

```text
world staging repo is incomplete; run world-plan --build first
```

For an intentional partial upload, inspect the staged `index.json` first, then
export that staged repo directly:

```bash
world=$HOME/.cache/laputa/world-<hash>
jq -r '.[] | [.arch,.name,.ver,.rel] | @tsv' "$world/index.json" | sort

set -a
. ./.env
set +a
docker run --rm --platform linux/arm64 \
  -e XSH_MODULE_PATH=/src/packages \
  -e XSH_PM_REPO=https://laputa.17166969.xyz \
  -e XSH_PM_PUBLIC_REPO=https://laputa.17166969.xyz \
  -e LAPUTA_TOKEN="$LAPUTA_TOKEN" \
  -v "$HOME/.cache/laputa":/root/.cache/laputa \
  -v "$HOME/d/laputa-systems/packages":/src/packages:ro \
  laputa-bootstrapped-build-essential-native:latest \
  /bin/xsh /src/packages/pm.xsh -- upload-repo-export \
  "/root/.cache/laputa/world-<hash>"
```

Verify the remote index afterward:

```bash
curl -fsSL https://laputa.17166969.xyz/index.json \
  | jq -r '.[] | select(.arch == "aarch64") | [.name,.ver,.rel] | @tsv' \
  | sort
```

## Source Mirrors

World package builds stage prepared source trees under
`<world>/.out/source-mirrors/` as deterministic `.tar.bz2` archives with
manifest sidecars. The remote index records each published archive hash in
`source_sha256`; the source object path is derived from package identity and
architecture. A mirror is uploaded only after its package build and proof
pass. Packages reused unchanged from the remote index do not create a new
mirror in that world stage.

When a source declaration, `prepare_sources()` hook, or generic normalization
rule changes, bump the package `rel` before rebuilding. A source checksum
mismatch may mean an upstream release artifact changed at the same URL; inspect
the new archive and update the declaration only when its contents are the
intended input.

For a local verification, compare the staged and published hashes:

```bash
world=$HOME/.cache/laputa/world-<hash>
pkg=<name>-<ver>-<rel>-<arch>
shasum -a 256 "$world/.out/source-mirrors/$pkg.tar.bz2"
curl -fsSL "https://laputa.17166969.xyz/sources/<name>/<name>-<ver>-<rel>-<arch>-src.tar.bz2" | shasum -a 256
```

## Common Failures

### Dirty Filesystem

```text
PmError.DirtyFilesystem: <pkg> would overwrite unowned <path>
```

This usually means a stale world root contains files not owned by PM's package
database. Delete the named world cache if the error reports one:

```bash
rm -rf ~/.cache/laputa/world-<hash>
```

If the error is from older PM output without a cache hint, clear all world
caches:

```bash
rm -rf ~/.cache/laputa/world-*
```

### Source Checksum Mismatch

```text
sha256 digest mismatch
```

For local `files/` sources, update checksums from the package repo:

```bash
cd ~/d/laputa-systems/packages
xsh pm.xsh -- update-checksums repo/<pkg>
```

If the package content changed, bump `rel` as well. For remote sources, inspect
the new tarball before accepting the checksum change:

```bash
curl -fsSL <url> | sha256sum
curl -fsSL <url> | tar -t | head
```

### Package Build Logs

World builds keep the main output focused on package state and write each
package build/proof stream to:

```text
~/.cache/laputa/world-<hash>/packages/<arch>/<pkg>/build.log
```

On failure, PM prints the failing package and log path. Start from that log
rather than rerunning with `WORLD_JOBS=1`; single-job reruns are only useful
when diagnosing scheduler or ordering behavior.

### Package Conflicts

```text
PmError.PackageConflict
```

Treat this as a packaging bug. Fix file ownership, `deps`, `replaces`, or
package layout rather than adding exceptions.

### Docker Resource Exhaustion

Symptoms include file descriptor exhaustion, signal 15 cancellations, or random
parallel subprocess failures. Reduce package parallelism:

```bash
make world-build WORLD_JOBS=2
```

The native-cross path on an amd64 Linux host is less constrained than macOS
Docker.

### Remote Download Drift

If a remote release tarball changes at the same URL, verify the new archive
layout before updating checksums. GitLab release artifacts and generated-source
tarballs are common offenders.

If a build now requires unavailable generators such as Python or a known-bad
tool, pre-generate the files on the host, add them under `files/`, and wire them
into `sources` with checksums.

## Verification

After a package or world change, use the narrowest proof that covers the change:

```bash
make package-test PKGNAME=<name>
make proof-rootfs
make boot
make installer-image
make installer-qemu-test
```

For browser/session proofs:

```bash
make dwl-foot-minimal-test
make waterfox-test
```

## Linux Kbuild Planner Oracle

The macOS arm64 Linux package path has an upstream Kbuild oracle benchmark.
It uses the warm Linux 7.0.5 source tree, the package's
`files/config/aarch64/base-aarch64.fragment`, and an Alpine arm64 container
with standard `build-base`, `bc`, `bison`, `flex`, and `perl` tools. The source
is mounted read-only and all generated output is placed in a separate out of
tree directory.

Laputa does materialize generated prerequisites before its archive-plan phase.
For arm64 preparation this includes generated config and ABI headers, the
VDSO, and the nVHE KVM object. The closest upstream comparison therefore runs:

```bash
make -j4 O=/out ARCH=arm64 prepare scripts
make -j4 O=/out ARCH=arm64 \
  arch/arm64/kernel/vdso/vdso.so \
  arch/arm64/kvm/hyp/nvhe/kvm_nvhe.o
make -j4 -n -k O=/out ARCH=arm64 vmlinux
```

The final command is intentionally a dry run. It emits the upstream build
graph without compiling the kernel, but exits 2 because a pristine dry-run
output tree cannot create the archive prerequisites `vmlinux.a` and
`drivers/firmware/efi/libstub/lib.a`. The output still reaches the top-level
archive/link graph and is useful as a planner measurement; do not treat its
exit status as a successful kernel build.

On July 14, 2026, with four jobs on the local macOS arm64 Docker path, the
upstream timings were:

| Phase | Wall time |
| --- | ---: |
| `prepare scripts` | 4.94 s |
| VDSO and nVHE prerequisites | 6.82 s |
| dry upstream Kbuild graph walk | 2.14 s |
| total before compilation | 13.90 s |

The dry run emitted 18,223 command lines. For comparison, the earlier
incomplete dry run without VDSO and nVHE materialization took 4.50 seconds and
emitted 18,394 lines, so that number is not the apples-to-apples baseline.

The oracle now accounts for EFI stub artifacts as well as ordinary compile
outputs. Upstream reports the `llvm-objcopy` results as relocatables named
`drivers/firmware/efi/libstub/*.stub.o`, while XSH creates those same artifacts
in the temporary arm64 final-build task list. The EFI `lib-*` sources are also
normalized to their equivalent `lib/*.o` objects; this covers `lib-cmdline.o`,
`lib-ctype.o`, and the FDT helpers without hiding a missing compile.

Archive ownership is tracked separately from normalized object paths. This is
required for Kbuild assignments such as `../vgic-v3-sr.o` in
`arch/arm64/kvm/hyp/vhe/Makefile`: the source path is in `hyp/`, but the object
belongs to the VHE archive. The gate compares flattened archive membership;
archive ordering is reported when it differs because nested archive layout can
represent the same member set.

Docker filesystem overhead is not the dominant explanation for the native XSH
planner gap. An earlier equivalent run measured 11.84 seconds for preparation
and dry planning with the source on a macOS bind mount, versus 10.25 seconds
with the source copied into a Docker volume. The roughly 1.6-second difference
is materially smaller than the current cold XSH discovery plus archive-plan
path, which is roughly 49–52 seconds. Use approximately 13.9 seconds as the
current upstream arm64 preparation-and-planning number to beat, while keeping
the dry-run prerequisite caveat in mind.
