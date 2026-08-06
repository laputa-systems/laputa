## Partial Upload Ergonomics

`WORLD_UPLOAD=1` only works for complete world stages. This is correct for a
full release, but awkward when intentionally publishing the first few tranches.

Possible fixes:

- Add a PM flag such as `world-plan --upload-partial` that exports the staged
  `index.json` without requiring `state.complete`.
- Or add a Makefile target that wraps `upload-repo-export` for the current world
  cache after printing the staged index for review.

## Source Mirroring

PM already downloads, stages, uploads, and consumes source mirrors. Package
source preparation checks the configured mirror first and falls back to the
upstream source when the mirror is missing. `pm download` creates the local
source mirror, `upload-set` uploads it with a built package, and
`upload-repo-export` uploads staged world mirrors and updates the source fields
in `index.json`. The `../mirror` service maps those objects to
`sources/<package>/...` and serves them to PM.

The current format is a processed, deterministic `.tar.bz2`: PM removes `.git`
directories, runs package-specific `prepare_sources` hooks, and writes a local
source manifest. There is no generic policy for deleting build-irrelevant
source files; packages must choose their own normalized subset. Linux 7.0.5 is
currently about 86 MiB as a source mirror after processing, while its extracted
tree is about 1.7 GiB.

Possible fixes:

- Add a mirror audit command for packages whose sources are not yet mirrored.
- Add an explicit source-normalization policy, preferably package opt-in rather
  than a global deletion list. Start with a Linux allowlist/exclude list and
  prove that the native Kbuild and package proofs still pass after removing
  documentation, tools, and other unused source families.
- Keep the source manifest format tied to package release identity until a
  policy-version field is needed for independent invalidation.
- Remove obsolete gzip source objects and old index fields when publishing the
  new repository shape; PM intentionally does not carry a legacy compatibility
  reader.
- Extend `source-audit` to check the public mirror object and remote hash when
  repository credentials are available.

## Bootstrap Package Upgrades

Packages such as `xsh`, `laputa-pm`, `musl`, and `llvm-toolchain` affect the
build runner, chroot base, or toolchain used to build later packages. They are
more fragile than ordinary leaves and need a clearer upgrade path.

Possible fixes:

- Add a documented bootstrap-package upgrade checklist covering cache busting,
  local `xsh`/`laputa-pm` use, chroot-base rebuilds, and staged upload order.
- Teach PM or the Makefile to invalidate the relevant world roots when these
  packages change, instead of relying on manual `~/.cache/laputa/world-*`
  cleanup.
- Add a narrow proof target that upgrades one bootstrap package and verifies
  that later tranches consume the freshly built package, not a stale remote one.

## Explicit Metapackages

Empty package definitions work, but package intent is implicit.

Possible fix:

- Add `export let metapackage: Bool = true` support in PM and teach proofs/index
  generation to represent it explicitly.

## Known Toolchain Quirks

Some generator tools have historically been fragile under arm64 Docker, notably
`bison` on certain parser inputs. The current workaround is to pre-generate
affected files on the host and add them as package sources.

Possible fixes:

- Rebuild or repin affected tools with known-good flags.
- Prefer checked-in generated files only for packages where the generator is not
  yet reliable in the target build environment.
