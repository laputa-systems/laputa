# Run the headless self-hosting proof

Use Linux x86_64 with writable KVM, QEMU, Docker, Python 3, jaq, flock, Git, Bash, and GNU tar. The saved disk-tools image must contain `/usr/sbin/debugfs` and `/sbin/mkfs.ext4`. Reserve 12 GiB and two CPUs for build phases. Runtime boot checks use 4 GiB and two CPUs. Rust uses two jobs.

## Prepare the saved inputs

Set these variables to exact saved inputs:

- `SOURCE_REPOSITORY`: the Laputa checkout containing this workflow.
- `FROZEN_XSH`: matching frozen `bin/{xsh,xshi,xsht}` and `core/` trees.
- `XSH_SOURCE`: the frozen source snapshot, including the authorized working-tree patch, without `.git`, `target`, or object caches.
- `VENDOR`: the complete Cargo.lock vendor directory for that source.
- `PM_SEED`: the canonical PM seed directory containing its existing manifest, binaries, core tree, and core archive.
- `SOURCE_CACHE`: the pinned source cache with `sha256/` entries for the selected package closure.
- `SAVED_ARTIFACTS`: the existing immutable PM artifact store.
- `SEED_IMAGE`: the saved xsh-test image ID containing nightly-2026-09-15 for x86_64 musl.
- `PACKAGE_TOOLS_IMAGE`: the saved package-tools image ID for composing A.
- `TOOLS_IMAGE`: the saved disk-tools image ID containing `debugfs` and `mkfs.ext4`; use the package-tools image when it contains both.
- `KACHE_TOOL` and `MOLD_TOOL`: the declared bootstrap executable paths.

Check that `.work/` is ignored through the checkout's local Git exclude. Create a disposable Laputa snapshot:

```sh
set -euo pipefail
git -C "$SOURCE_REPOSITORY" check-ignore .work/
REPOSITORY="$SOURCE_REPOSITORY/.work/tmp/self-hosting/repository"
INPUT_ROOT="$REPOSITORY/.work/input-root"
OUTPUT_ROOT="$REPOSITORY/.work/output"
ARTIFACTS="$REPOSITORY/.work/artifacts"
CONTEXT="$REPOSITORY/.work/context"
XSH="$FROZEN_XSH/bin/xsh"
mkdir -p "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$ARTIFACTS"
(
  cd "$SOURCE_REPOSITORY"
  git ls-files -z --cached --others --exclude-standard |
    tar --null --files-from=- -cf -
) | tar -C "$REPOSITORY" -xf -
mkdir -p "$REPOSITORY/.out/seed/x86_64" "$REPOSITORY/.cache/sources"
cp -R "$PM_SEED/." "$REPOSITORY/.out/seed/x86_64/"
cp -R "$SOURCE_CACHE/." "$REPOSITORY/.cache/sources/"
cp -R "$SAVED_ARTIFACTS/." "$ARTIFACTS/"
```

Construct the existing closed-build scratch image with explicit seed inputs:

```sh
mkdir -p "$CONTEXT/bin" "$CONTEXT/core" "$CONTEXT/links/usr/bin"
for name in xsh xshi xsht; do
  cp "$FROZEN_XSH/bin/$name" "$CONTEXT/bin/$name"
done
cp "$FROZEN_XSH/core/"*.xsh "$CONTEXT/core/"
cp -R "$FROZEN_XSH/core/lib" "$CONTEXT/core/lib"
cp "$KACHE_TOOL" "$CONTEXT/bin/kache"
cp "$MOLD_TOOL" "$CONTEXT/bin/mold"
chmod 0755 "$CONTEXT/bin/kache" "$CONTEXT/bin/mold"
cp "$REPOSITORY/pm.xsh" "$CONTEXT/pm.xsh"
cp -R "$REPOSITORY/pm" "$CONTEXT/pm"
cp -R "$REPOSITORY/tests/docker/fixtures/closed-build" "$CONTEXT/cohort"
mkdir -p "$CONTEXT/cohort/pm"
cp "$REPOSITORY/pm/proof.xsh" "$CONTEXT/cohort/pm/proof.xsh"
cp "$CONTEXT/cohort/probe.c" "$CONTEXT/probe.c"
ln -s ../lib/llvm23/bin/clang "$CONTEXT/links/usr/bin/clang"
SCRATCH_IMAGE="laputa-self-hosting-inputs:local"
docker build --network none --pull=false --build-arg "SEED_IMAGE=$SEED_IMAGE" \
  -f "$REPOSITORY/tests/docker/closed_build.Dockerfile" -t "$SCRATCH_IMAGE" "$CONTEXT"
container=$(docker create "$SCRATCH_IMAGE" /bin/xsh)
docker export "$container" | tar -C "$INPUT_ROOT" -xf -
docker rm "$container"
```

Stage the frozen source, vendor, and workflow. Preserve Clang's canonical resource-directory path and the saved image's libc alias:

```sh
mkdir -p "$INPUT_ROOT/inputs/laputa" "$INPUT_ROOT/inputs/xsh" \
  "$INPUT_ROOT/inputs/vendor" "$INPUT_ROOT/src/laputa" "$INPUT_ROOT/artifacts" \
  "$INPUT_ROOT/output" "$INPUT_ROOT/scratch" "$INPUT_ROOT/proc" "$INPUT_ROOT/dev"
tar -C "$REPOSITORY" --exclude='./.work' --exclude='./.out' --exclude='./.cache' -cf - . |
  tar -C "$INPUT_ROOT/inputs/laputa" -xf -
cp -R "$XSH_SOURCE/." "$INPUT_ROOT/inputs/xsh/"
cp -R "$VENDOR/." "$INPUT_ROOT/inputs/vendor/"
cp "$REPOSITORY/guest/self-hosting-build.xsh" "$INPUT_ROOT/inputs/build.xsh"
cp -R "$CONTEXT/cohort" "$INPUT_ROOT/checkout-one"
cp -R "$CONTEXT/cohort" "$INPUT_ROOT/checkout-two"
ln -s ../../lib/ld-musl-x86_64.so.1 "$INPUT_ROOT/usr/lib/libc.so"
```

## Build and qualify the replacement

Build A through the existing profile builder:

```sh
XSH_MODULE_PATH="$REPOSITORY" "$XSH" "$REPOSITORY/seed/self_hosting_profile.xsh" -- \
  "$REPOSITORY" "$ARTIFACTS" "$OUTPUT_ROOT" "$PACKAGE_TOOLS_IMAGE"
cp -R "$PM_SEED" "$INPUT_ROOT/inputs/seed-A"
cp -R "$ARTIFACTS" "$INPUT_ROOT/inputs/artifacts-A"
cp -R "$SOURCE_CACHE" "$INPUT_ROOT/inputs/source-cache"
cp "$OUTPUT_ROOT/current/generation.json" "$INPUT_ROOT/inputs/generation-A.json"
"$REPOSITORY/tests/integration/self_hosting.sh" compile \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH"
"$REPOSITORY/tests/integration/self_hosting.sh" qualify \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH"
```

The compile phase requires a missing output disk and creates an empty 24 GiB filesystem. The driver normalizes copied modes through PM's checkout policy. A UID 65534 probe reads every regular input file, checks writable output and scratch, and opens `/dev/null` before formatting the input disk. The guest runs Cargo offline with the pinned toolchain, as UID 65534 inside a chroot and private network namespace. kache receives no host object cache.

Qualification compares baseline and replacement package keys, payload digests, and archive bytes for the existing C, Rust, and XSH cohort. Existing artifact metadata must name the runners that executed each build. The replacement runs the existing long-double printf and arbitrary-precision seq tests.

## Compose and boot the successor

```sh
"$REPOSITORY/tests/integration/self_hosting.sh" compose \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH"
"$REPOSITORY/tests/integration/self_hosting_successor.sh" \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH"
```

Inside A, the compiled runners populate B's existing seed format. PM builds the selected closure and composes a matching kernel/root bundle, including the closed cohort. PM reuses immutable A kernel artifacts. Source mounts remain read-only during execution. The guest publishes the complete bundle beneath `/successor` on the output disk.

The host extracts the completed bundle with debugfs. Before boot, the verifier reads the actual root filesystem receipt, compares the selected PM kernel, and compares every GPT root-partition byte against the root filesystem. Stale-generation, A-root/B-disk, A-disk/B-root, and altered-kernel candidates must fail for their specific invariants. A's kernel, root filesystem, disk, and receipt bytes must remain unchanged across rejection.

B must report its expected running generation, differ from A, and have installed runner hashes equal to the actual guest compilation outputs. B executes the C and Rust payloads and reads the XSH payload. The driver publishes verified A and B bundles into the normal activation store. It admits their exact kernel and disk hashes under a local development policy, stages B, and boots through `qemu.boot_command_argv`.

Two deliberate B health failures exhaust the normal attempt budget and select A. The driver checks A's receipt and seed runner hashes after fallback. It then restages B, verifies B's receipt, boot serial, runner hashes, and payload behavior, and calls the normal manual confirmation operation. Finally it stages and confirms A as an operator rollback. The driver compares A's bundle hashes and the mutable build-volume hash across the failed boots and rollback. Both root disks use the existing launcher's snapshot mode.

## Rebuild selected packages with installed tools

Use this shorter path to change the installed `baselayout` package without rebuilding XSH. Prepare the same declared tool root, Laputa snapshot, seed, artifact store, and source cache. Omit the XSH source and Cargo vendor copies. Keep `inputs/seed-A`, `inputs/artifacts-A`, `inputs/source-cache`, and `inputs/generation-A.json`. Use a saved disk-tools image containing both `debugfs` and `mkfs.ext4`; the package build image and disk-tools image may differ.

Save A's `etc/os-release` as `inputs/previous-os-release`. Write the intended replacement to `inputs/development-os-release`. The two files must differ. The guest copies that declared edit into its disposable `packages/baselayout/files/rootfs/etc/os-release` source before invoking normal PM. Keep the repository's package sources unchanged on the host.

Install A's verified bundle into the local activation store before building inside A:

```sh
XSH_MODULE_PATH="$REPOSITORY" "$XSH" "$REPOSITORY/seed/self_hosting_activation.xsh" -- \
  install "$OUTPUT_ROOT" "$OUTPUT_ROOT/current" "$OUTPUT_ROOT/current/vmlinuz" "$TOOLS_IMAGE"
"$REPOSITORY/tests/integration/self_hosting.sh" compose-package \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH"
"$REPOSITORY/tests/integration/self_hosting_successor.sh" \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH" installed-tools
```

Start with a missing `output.ext4`. The package phase creates the same empty 24 GiB build volume as the source-build phase. Each phase formats a 12 GiB read-only input disk. A verifies that the declared seed runners equal its installed runners before invoking the existing successor composer. The composer rebuilds `baselayout` and builds the C, Rust, and XSH cohort through normal PM, then produces B. B must contain the intended `os-release` bytes and a different `baselayout` artifact key. Both A recovery boots require the original file. This mode compares B's installed runners to the declared A seed; it does not claim an XSH source rebuild.

Keep the closed cohort's sources and tools unchanged when checking its existing payload assertions. For a component change, update the owning behavior regression with the intended result before running the successor proof.

To reproduce the 2026-11-12 Linux x86_64/KVM selected-package input set, use Laputa base `b4bc8a8a87acf8eeffa74ed0ede727303921d3cd` with this workflow. Keep these declared bootstrap identities:

- Seed xsh SHA-256: `6b001589607bf7723e38e53496d9bb3ce7f5fc5bde2ac131fd4c7d42200754de`.
- Seed xsht SHA-256: `744e89ae2c55230fa2fe2d0b4eaaba2eefc76184804b2c223399af81bbcc1379`.
- The seed manifest records XSH `131ccc686b6afcf8a47981176d9985d839f5f54c` with a dirty source tree. The binary hashes identify the supplied products; this result does not qualify a clean build of that source revision.
- Package-tools image: `sha256:d2bf78f7f521a0992f72b620632fe31fb88ccbe5433e41240a5ddc7064c8f397`.
- Saved declared tool-root image: `sha256:cbe8e464fc60abc466bc08467f335476428299294446db8b85e973b6d21db4cc`.
- Disk-tools image: `sha256:2d6f716aada6a0161fbf11d9b1a53c16fbc7747ab95c1e339c6aefdc07a56911`.
- Reused Linux kernel SHA-256: `6207db4b3bfa96545a468ef37242fa795f298323314feb42737d53d5fb7d71d0`.

Write these three lines, ending with a newline, as the development `os-release` input:

```text
NAME="Laputa Linux"
ID=laputa
BUILD_ID="self-hosted-baselayout"
```

The rebuilt `baselayout` artifact key is `5b68612a6560f600bd493fddffbf1e0acb080163f00e16df27d9a75b323d0668`; A's original key is `243fbf890a1f205daeddac93860b3c835bb94d7126f4095b6f801ee49792c3e8`.

The recorded combined `self_hosting_successor.sh ... installed-tools` run exits zero. A is generation `906009468ffe783b2078aacfe5f1002e7294a15ac57712e50a2d09766229a8a5`; B is `9c6c2e501c9763fa8636699ba68e25d440a18914bcbded9f8f4128d00959230d`. Two deliberate B failures restore A. B then passes the actual receipt, runner, package-key, metadata, and C/Rust/XSH behavior checks and confirms at boot serial 3. Operator rollback confirms A at serial 4. A's four bundle hashes and the complete mutable build-volume hash remain equal before and after the sequence. The focused activation, launcher, QEMU, and self-hosting native checks pass 65 tests; the host-lock regression also passes.

## Run the guest replay fixtures

```sh
"$REPOSITORY/tests/integration/self_hosting.sh" replay \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH"
```

The clock fixture changes only the disposable guest's wall clock, exercises readiness, restart, and stop budgets, and restores the clock. The host stops and resumes QEMU once, with three seconds between acknowledgments. A resume marker preceding the stop acknowledgment invalidates the attempt. Guest monotonic time need not include the host pause.

The qualified lifecycle fixture checks canonical descendant cleanup before finish and respawn. Its deliberate wrong-copy replay must report the surviving-descendant invariant and clean up both process groups. The network fixture records one successful address request followed by an invalid-gateway failure and rejects subsequent ownership inference. It does not qualify general network convergence or address withdrawal.

## Preserve the execution boundaries

Run the bounded host-lock regression:

```sh
"$REPOSITORY/tests/integration/self_hosting_lock_test.sh" "$REPOSITORY"
```

Every phase acquires nonblocking locks for the canonical input root, output root, and backing output disk before changing inputs or formatting. A competing phase fails immediately. Backing disks must stay under the disposable repository's `.work/` and have one hard link. Runtime boots retain the same output root and backing-disk lock. Their input disk contains only proof scripts, declared seed tools, receipts, and expected package metadata; compiler and source-cache inputs remain in the original input root.

Runtime boots attach the completed build volume as a read-only block device. The successor verifies that authority through sysfs and mounts the synced ext4 outputs with `ro,noload`. An ext4 `ro` mount alone can replay the journal and write metadata. This inspection path does not qualify recovery of interrupted builds or damaged filesystems.

The installed boot hook validates the canonical PM generation receipt and disposable-guest kernel token before invoking the declared input entry. The entry is trusted guest-root code. Never run guest entries on the host or in Docker. The host supervisor owns QEMU, cancels it on failure or deadline, and bounds each QMP helper to five seconds.

The linker uses declared Clang, mold, and Rust self-contained CRT objects. Target flags retain the exact two static-musl aliases owned by the pinned XSH build contract: `__isoc23_sscanf=sscanf` and `__isoc23_strtol=strtol`. Host proc macros receive neither alias. Remove this bootstrap exception after qualifying a replacement SDK against the upstream XSH link contract.

This is a local Linux x86_64 development proof. Release trust, remote admission, automatic promotion, aarch64, Asterinas, and interactive xshi remain unqualified. The bootstrap xshi remains the existing stub. The successor reuses the existing Linux kernel artifact.


## Check the debug driver stack

After the source, successor, and guest replay proofs, run one bounded debug-driver check:

```sh
"$REPOSITORY/tests/integration/self_hosting.sh" debug \
  "$REPOSITORY" "$INPUT_ROOT" "$OUTPUT_ROOT" "$TOOLS_IMAGE" "$XSH"
```

The guest runs the frozen source's exact `cargo dev --help` alias with its default dev profile. It sets and reads back soft and hard stack limits of 8,388,608 bytes. The build uses two jobs, a separate empty `target-debug` directory, offline crates, and a 1,200-second command deadline. The serial log records the stack limits and Cargo exit status. The qualified supplied source prints help and exits zero; the previously reported stack overflow is not reproduced.
