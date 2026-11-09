# TODO

Prefix: GLU
Next: 14

### GLU-9 · P3 · engine is not on the user build path
- **Area:** engine
- **Where:** `crates/engine/src/lib.rs:38`
- **Problem:** `execute` forwards to ninja and has no production caller. Bins never depend on the crate. The old architecture text called it the shared executor.
- **Recommendation:** Either make setup and build go through one executor, or stop presenting `engine` as that executor. Do not teach Meson semantics to it.
- **Fix with:** architect
- **Effort:** L

### GLU-10 · P3 · build_state drops the generated manifest and builds a second graph
- **Area:** meson
- **Where:** `crates/meson/src/backend.rs:73`
- **Problem:** `build_state` calls `generate`, discards the text, then hand-builds edges. The only caller is the equivalence test, which does not compare commands. The two lowerings can drift with no user-visible failure today.
- **Recommendation:** Parse the generated `build.ninja` in the test, or delete `build_state` if nothing else needs it.
- **Fix with:** deduplicate
- **Effort:** M

### GLU-11 · P3 · serde is still in the resolved lock
- **Area:** dependencies
- **Where:** `Cargo.lock:517`, `Cargo.lock:477`
- **Problem:** P-4 records that serde was replaced. `rust_decimal` still depends on `serde` and `serde_json`, so both stay in the lock.
- **Recommendation:** Drop `rust_decimal` or a feature that pulls serde, and measure the binary-size delta before deleting it.
- **Fix with:** none
- **Effort:** S

### GLU-12 · P3 · the compiler pin is a record, not a toolchain file
- **Area:** build
- **Where:** `tests/upstream/PINS`
- **Problem:** PINS records rustc 1.98.0. There is no `rust-toolchain.toml`. CI and release use whatever `rustup show` selects. The release cache key hashes `rust-toolchain.toml`, which is absent.
- **Recommendation:** Add the toolchain file only when the owner asks to pin it. Until then, do not treat PINS as what CI compiled with.
- **Fix with:** none
- **Effort:** S

### GLU-13 · P4 · meson-logs is created and never written
- **Area:** meson
- **Where:** `crates/meson/src/cli.rs:673`
- **Problem:** Setup creates `meson-logs` and leaves it empty. Failures still go only to stderr.
- **Recommendation:** Write the log the directory is for, or stop creating it.
- **Fix with:** none
- **Effort:** S
