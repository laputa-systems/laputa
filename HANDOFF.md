# Laputa world-build handoff

Updated July 13, 2026 on macOS while running the aarch64 Docker world build.
The build is currently active in tranche 5, compiling Linux. No remote push was
performed, and the world-build attempts did not use `WORLD_TO_TRANCHE`.

## Current command and cache

The requested full command is:

```sh
make world-build WORLD_JOBS=8
```

The world cache is:

```text
~/.cache/laputa/world-2fed4988d6e8c6c6a6fb11d12d9d3987d6f1bb572c470d013d2736f57ccb69cc
```

The current Docker container is running the build. If the build is interrupted,
the cache is reusable; do not delete it unless PM reports a stale
`DirtyFilesystem` root.

## What is complete

- `SOURCES.md` was removed after its behavior was absorbed into durable docs.
- `boot.xsh` now creates `/bin/sh -> /bin/xsh`, matching the package behavior;
  it no longer points to `/bin/xshi`.
- The package `xsh` filetree and install logic declare and install the `sh`
  symlink. Its rel is 12 in the current local package state.
- `laputa-pm` was bumped because the xsh filetree changed.
- The Cargo package filetree declares the aarch64 Rust proc-macro shared
  libraries that PM previously rejected as undeclared binaries.
- `repo/cargo/proof.xsh` creates and builds a real minimal Cargo crate, then
  runs the resulting static `hello cargo` binary directly. Cargo and rustc are
  still invoked through the target musl loader. It is not merely checking
  Cargo and rustc version output.
- `gnu-stubs` rel29 built, staged, and passed its package proof in the current
  aarch64 world cache.
- The small tranche-4 packages were built and staged at `WORLD_JOBS=8` before
  Cargo failed: mdevd, pkgconf, samurai, alsa-lib, bison, eudev-lite, flex,
  iptables, and less.
- Cargo rel10 built, passed its real crate proof, and was staged. The proof
  output includes `cargo ok: hello cargo`.
- In tranche 5, alsa-ucm-conf, muon, tailscale, and cmake built successfully.
  Linux rel34 is currently the only active package.

## The gnu-stubs fix

The original failure was that the aarch64 `rust-lld` binary could not start:

```text
Error relocating .../rust-lld:
  __floatunditf: symbol not found
  __divtf3: symbol not found
  __clear_cache: symbol not found
  __unordtf2: symbol not found
  __extendsftf2: symbol not found
  __trunctfdf2: symbol not found
  __getf2: symbol not found
  __multf3: symbol not found
  __letf2: symbol not found
  __floatsitf: symbol not found
  __gttf2: symbol not found
```

The important finding is that compiler-rt archive members contain the real
implementations, but those helper symbols are hidden. Linking the archive
with `--whole-archive`, or passing the archive members directly, did not make
them dynamic exports.

Current `repo/gnu-stubs/PKGBUILD.xsh` rel29 does the following for a native
aarch64 or x86_64 build:

1. Extracts only the eight relevant compiler-rt members:
   `comparetf2.c.o`, `divtf3.c.o`, `extendsftf2.c.o`, `floatsitf.c.o`,
   `floatunditf.c.o`, `multf3.c.o`, `trunctfdf2.c.o`, and `clear_cache.c.o`.
2. Uses `llvm-objcopy --set-symbols-visibility=<map>=default` on those
   objects for the eleven required helper names.
3. Links the objects and the real prebuilt `libunwind.a` with the target
   `ld.lld`, adding the musl `/usr/lib` search path plus `-ldl -lpthread`.
4. Produces `crtbeginS.o`, `crtendS.o`, `libgcc_s.so`, and the
   `libgcc_s.so.1 -> libgcc_s.so` symlink.

No fake compiler-runtime implementations remain. The code is guarded by
`build_arch == target_arch` and accepts only aarch64 or x86_64, but amd64 still
needs a native verification run before this can be considered safe for both
world-build paths.

The rel29 artifact was manually checked before the Cargo proof. This command
showed all eleven required dynamic symbols:

```sh
docker run --rm --platform linux/arm64 \
  -v "$HOME/.cache/laputa":/root/.cache/laputa \
  laputa-bootstrapped-build-essential-native:latest \
  /usr/lib/ld-musl-aarch64.so.1 /usr/lib/llvm22/bin/llvm-nm -D \
  /root/.cache/laputa/world-2fed4988d6e8c6c6a6fb11d12d9d3987d6f1bb572c470d013d2736f57ccb69cc/.work/world-build/gnu-stubs-22.1.8-29/root/var/tmp/pm-build/gnu-stubs-22.1.8-29/dest/usr/lib/libgcc_s.so
```

## Cargo proof status

With gnu-stubs rel29, the bundled Rust `rust-lld` got past the previous
missing-relocation failure but then crashed while linking the hello crate:

```text
signal: pipeline segment 0 .../rust-lld ... terminated by signal 11
fatal runtime error: failed to initiate panic
```

The Cargo proof was then changed in `repo/cargo/proof.xsh` to use the actual
target LLVM linker ELF:

```text
/usr/lib/llvm22/bin/ld.lld
```

Cargo rel was bumped from 9 to 10. The first rel10 attempt showed that
`rustc` passes GCC-driver options to a direct `ld.lld` invocation. The proof
now expands `-Wl,` options and drops only `-nostartfiles` and
`-nodefaultlibs`, which are driver-only flags. That produced a valid static
binary; the proof then needed to execute that binary directly instead of
passing it to the musl dynamic loader.

The subsequent rel10 run passed and staged successfully. Its final build log
is at:

```text
~/.cache/laputa/world-2fed4988d6e8c6c6a6fb11d12d9d3987d6f1bb572c470d013d2736f57ccb69cc/packages/aarch64/cargo/build.log
```

The active command remains:

```sh
make world-build WORLD_JOBS=8
```

It is compiling Linux rel34 in tranche 5. Let it continue through the
remaining tranches without adding a tranche limit.

## Source mirror status

The cache has reached Linux rel34 and its active work directory is about
1.8 GB, consistent with the expected extracted Linux source tree. The build
has not yet completed Linux, so the source mirror and extracted-tree shape
still need validation after the package finishes. Do not infer source-mirror
correctness from size alone.

After the full build reaches Linux, inspect the mirror before considering that
part complete. Useful checks are:

```sh
cache="$HOME/.cache/laputa/world-2fed4988d6e8c6c6a6fb11d12d9d3987d6f1bb572c470d013d2736f57ccb69cc"
find "$cache" -path '*linux*source-mirrors*' -print
find "$cache" -path '*linux*' -type f \( -name '*.tar.*' -o -name '*.tar.gz' \) -print
du -sh "$cache"/.*linux* "$cache"/*linux* 2>/dev/null
```

The extracted Linux tree is expected to be large; the prior estimate was
approximately 1.7 GB. Check that the mirror is a coherent archive/source tree,
has the expected Linux top-level directory, and does not accidentally contain
an unrelated nested world root or transient build output.

## Worktree state at handoff

Laputa checkout status:

```text
M  PLAYBOOK-WORLD-BUILD.md
D  SOURCES.md
M  boot.xsh
```

Packages checkout status:

```text
 M repo/cargo/PKGBUILD.xsh
 M repo/cargo/proof.xsh
 M repo/gnu-stubs/PKGBUILD.xsh
```

The package repository may also contain earlier user changes not shown in this
short handoff. Preserve them. Do not reset either checkout. Before resuming,
run:

```sh
../xsh/target/debug/xsht check ../packages/repo/cargo/proof.xsh
../xsh/target/debug/xsht check ../packages/repo/gnu-stubs/PKGBUILD.xsh
git diff --check
git -C ../packages diff --check
```

No commits or pushes were made as part of this handoff.

## Safety checks before declaring completion

1. Let the active macOS aarch64 world build finish with `WORLD_JOBS=8` and no
   `WORLD_TO_TRANCHE`.
2. Validate the Linux source mirror and extracted-tree shape after Linux
   finishes.
3. Run a native amd64 package/world validation of the new gnu-stubs path on
   `threadripper`; at minimum build/prove gnu-stubs and Cargo there, and then
   use the existing `make world-build-amd64` workflow as appropriate.
4. Only after those checks consider uploading the newly built local artifacts.
