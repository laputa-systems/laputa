# TODO

Prefix: GLU
Next: 28

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

### GLU-27 · P2 · install and postconf scripts are silently skipped
- **Area:** meson
- **Where:** `crates/meson/src/builtins/methods.rs` (`meson.add_install_script`, `add_postconf_script`, `add_dist_script` map to `meson_noop`)
- **Problem:** A project whose install relies on `meson.add_install_script` gets a tree missing whatever the script would have written, and setup still succeeds. Meson runs install scripts with `MESON_INSTALL_PREFIX`, `MESON_INSTALL_DESTDIR_PREFIX` and the other documented variables after files are installed, and postconf scripts after setup.
- **Recommendation:** Record install scripts and run them from `meson install` with Meson's environment, run postconf scripts at the end of setup, and fail on a script Gluon cannot run rather than skip it. Add a fixture compared with reference Meson.
- **Fix with:** reference-parity
- **Effort:** M

### GLU-26 · P3 · find_library with dirs skips the link check and system directories
- **Area:** meson
- **Where:** `crates/meson/src/compilers.rs` (`find_library`)
- **Problem:** with `dirs:` Meson tries each naming pattern in the given directories and then in the compiler's system library directories, and link-checks each candidate (except static-only requests). gluon only checks whether the file exists in `dirs` and returns the first match, so a library present only in a system directory is reported missing, and a file that does not link is accepted.
- **Recommendation:** Mirror `_find_library_real`: search `extra_dirs` followed by `get_library_dirs()` and probe candidates by linking a shared library.
- **Fix with:** reference-parity
- **Effort:** M
