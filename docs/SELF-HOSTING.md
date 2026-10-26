# Run the headless self-hosting proof

Use Linux x86_64 with writable KVM, QEMU, Docker, Python 3, jaq, flock, Git, Bash, and GNU tar. The saved package-tools image must contain `/usr/sbin/debugfs` and `/sbin/mkfs.ext4`. Reserve 12 GiB and two CPUs for the guest. Rust uses two jobs.

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
- `TOOLS_IMAGE`: the saved package-tools image ID.
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
  "$REPOSITORY" "$ARTIFACTS" "$OUTPUT_ROOT" "$TOOLS_IMAGE"
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

B must report its expected running generation, differ from A, and have installed runner hashes equal to the actual guest compilation outputs. B executes the C and Rust payloads and reads the XSH payload. A then boots again and must report its original receipt and seed runner hashes. Both root disks use the existing launcher's snapshot mode.

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

Every phase acquires nonblocking locks for the canonical input root, output root, and backing output disk before changing inputs or formatting. A competing phase fails immediately. Backing disks must stay under the disposable repository's `.work/` and have one hard link. B's output-disk symlink shares A's backing-disk lock.

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
