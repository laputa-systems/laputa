Prefix: GLU
Next: 33

### GLU-29 · P2 · ninja drops trailing whitespace from variable values, breaking CMake compiler launchers

- **Area:** ninja
- **Where:** `crates/ninja/src/manifest.rs` (variable value parsing)
- **Problem:** Ninja keeps a variable value's trailing spaces, and CMake relies on it: build.ninja sets `LAUNCHER = /path/to/launcher ` and rules run `command = ${LAUNCHER}${CODE_CHECK}/usr/bin/c++ ...`. gluon's ninja (release dd4b9664d3319e7dc9d01bd895c72d57aa298244, aarch64-apple-darwin, reports 1.13.2) strips the space, so every CMake project configured with CMAKE_<LANG>_COMPILER_LAUNCHER fails with `ninja: failed to spawn: /path/to/launcher/usr/bin/c++: Not a directory (os error 20)`. Found building LLVM 21.1.8 with kache as the launcher. Minimal repro: `printf 'rule r\n  command = ${PRE}echo -n ok > $out\nbuild out1: r\n  PRE = env \n' > build.ninja && ninja` succeeds with Ninja 1.13 (runs `env echo -n ok`) and fails with gluon.
- **Recommendation:** Preserve trailing whitespace in variable values as Ninja's lexer does (only leading whitespace after `=` is skipped), and add the repro above as a differential fixture.
- **Fix with:** reference-parity

### GLU-30 · P2 · wrap downloads skip source_hash and patch_hash
- **Area:** meson
- **Where:** `crates/meson/src/wrap.rs:105-140`, `crates/meson/src/wrap.rs:175`, `crates/meson/src/wrap.rs:235`, `crates/meson/src/builtins/functions.rs:3178`
- **Problem:** A subproject without a pre-extracted tree runs the wrap download, which fetches with curl or copies from packagefiles/packagecache and extracts without ever reading the wrap's `source_hash` or `patch_hash` (neither name appears in wrap.rs). A compromised source server, an HTTP path or a poisoned cache can therefore replace build inputs that the wrap pins, and attacker-controlled build files then run. `wrap_mode` is fixed at `default` (`crates/meson/src/builtins/functions.rs:4032`), so nothing disables downloads.
- **Recommendation:** Verify the declared source and patch hashes before extracting downloaded or cached bytes and fail closed on a mismatch or a missing hash; honour `--wrap-mode=nodownload`. Acceptance: a wrap whose source or patch hash mismatches fails before extraction, and a correctly pinned archive builds.
- **Fix with:** security
- **Effort:** M

### GLU-31 · P3 · differential no-op check counts the original build's edges
- **Area:** tests
- **Where:** `tests/differential/run.sh:213-227`
- **Problem:** After the no-op rebuild, the harness compares edge counts from `build.log` and `cand_build.log` (the first builds) instead of `noop.log` and `cand_noop.log`, so a candidate that reruns every edge on every invocation passes the no-op contract.
- **Recommendation:** Count edges in the no-op logs and require zero for both, as Meson's no-op contract states. Acceptance: a candidate that rebuilds one edge on a no-op run fails the fixture.
- **Fix with:** test-audit
- **Effort:** S

### GLU-32 · P3 · differential harness passes fixtures where both builds fail
- **Area:** tests
- **Where:** `tests/differential/run.sh:118-128`, `tests/differential/run.sh:139-144`
- **Problem:** Matching nonzero setup or build exits are reported as `PASS ... both-fail`, including for positive fixtures such as a trivial executable, so a missing compiler or another shared environmental failure makes the parity gate pass without comparing any output.
- **Recommendation:** Allow a both-fail pass only for fixtures marked as expected to fail, and fail positive fixtures whose reference build does not succeed. Acceptance: removing the C compiler from PATH fails the positive fixtures instead of passing them.
- **Fix with:** test-audit
- **Effort:** S

### GLU-19 · P3 · shared libraries have no symbol-extractor edge

- **Area:** meson
- **Where:** `crates/meson/src/backend.rs`, `tests/differential/fixtures/meson/shared-args/skip-edge-count`
- **Problem:** Meson 1.12.1 adds a `SHSYM` edge per shared library so relinks skip dependents whose exported symbols did not change; gluon emits none, so the `gnu-symbol-visibility` and `shared-args` fixtures skip the edge-count comparison.
- **Recommendation:** Emit the symbol-extractor edge and make dependents' links depend on the `.symbols` output, then delete the `skip-edge-count` markers.
- **Fix with:** reference-parity
- **Effort:** M

### GLU-20 · P3 · install accepts options it does not apply

- **Area:** meson
- **Where:** `crates/meson/src/cli.rs`, `crates/meson/src/install.rs`
- **Problem:** `meson install --tags` and `--skip-subprojects` are parsed and silently ignored, and `configure_file`'s `install_mode` never reaches the install plan, so those installs get default modes.
- **Recommendation:** Apply each as Meson 1.12.1's `minstall.py` does, or reject it with an error until it is implemented.
- **Fix with:** reference-parity
- **Effort:** S

### GLU-21 · P3 · shared-library aliases are missing from the build directory

- **Area:** meson
- **Where:** `crates/meson/src/backend.rs`, `crates/meson/src/install.rs`
- **Problem:** Meson creates `libfoo.so`/`libfoo.dylib` and `libfoo.so.<soversion>` symlinks in the build directory at setup (`generate_shlib_aliases`). gluon creates them only in the install plan, so build-tree consumers that open the unversioned name fail and `intro-installed.json` and `build all` disagree with Meson about the build outputs.
- **Recommendation:** Create the same aliases next to the versioned build output at setup, matching `SharedLibrary.get_aliases()`.
- **Fix with:** reference-parity
- **Effort:** S

### GLU-22 · P3 · install does not rewrite dependent load paths

- **Area:** meson
- **Where:** `crates/meson/src/install.rs`
- **Problem:** ELF RPATH/RUNPATH is rewritten in process and `install_name_tool -id` is applied to installed dylibs, but Meson also runs `install_name_tool -change` from `get_link_deps_mapping()` for build targets the library links. A macOS library that links another target of the same project keeps the build-tree install name after install.
- **Recommendation:** Pass the linked targets' install-name mappings to `install_name_tool`.
- **Fix with:** reference-parity
- **Effort:** M

### GLU-23 · P3 · pkgconfig ignores library targets in requires

- **Area:** meson
- **Where:** `crates/meson/src/modules/pkgconfig.rs`
- **Problem:** Meson maps a library target passed to `requires`/`requires_private` to the `filebase` of the `.pc` generated for it (and errors otherwise). gluon only handles strings and dependency objects, silently dropping library objects.
- **Recommendation:** Track generated `.pc` metadata per target id so `DependenciesHelper` can recurse as Meson does.
- **Fix with:** reference-parity
- **Effort:** M

### GLU-24 · P3 · uninstalled pkgconfig file is approximate

- **Area:** meson
- **Where:** `crates/meson/src/modules/pkgconfig.rs`
- **Problem:** the `meson-uninstalled/*-uninstalled.pc` Cflags are derived from each target's `include_directories` plus subdir. Meson builds them from `IncludeDirs.incdirs` plus `extra_build_dirs` for every processed library and nested link target, so paths that come from implicit or dependency include directories can be missing.
- **Recommendation:** Record the uninstalled include directories while processing the dependency graph, as `DependenciesHelper._add_uninstalled_incdirs` does.
- **Fix with:** reference-parity
- **Effort:** S

### GLU-26 · P3 · find_library with dirs skips the link check and system directories

- **Area:** meson
- **Where:** `crates/meson/src/compilers.rs` (`find_library`)
- **Problem:** with `dirs:` Meson tries each naming pattern in the given directories and then in the compiler's system library directories, and link-checks each candidate (except static-only requests). gluon only checks whether the file exists in `dirs` and returns the first match, so a library present only in a system directory is reported missing, and a file that does not link is accepted.
- **Recommendation:** Mirror `_find_library_real`: search `extra_dirs` followed by `get_library_dirs()` and probe candidates by linking a shared library.
- **Fix with:** reference-parity
- **Effort:** M

