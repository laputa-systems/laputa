# Architecture

Workspace members are listed in [`Cargo.toml`](../Cargo.toml).

- `crates/graph` holds `State`, `Rule`, and `Edge`.
- `crates/state` owns `.ninja_log` and `.ninja_deps`.
- `crates/ninja` parses the manifest, schedules edges, and runs them. This is the build users run.
- `crates/meson` is the Meson front end. Setup writes `build.ninja` and `meson-info/`. Compile, test, and install invoke `ninja` from `PATH`.
- `crates/engine` is a queue helper plus `execute`, which forwards to `ninja::build::run`. No binary calls it. It does not depend on Meson semantics.
- `bins/meson`, `bins/ninja`, and `bins/build` are wrappers. `gluon-build meson` builds a fresh argument list. `gluon-build ninja` calls `ninja::main_entry`, which reads the process arguments again.

`build.ninja` is the interchange file. `NinjaBackend::build_state` builds a typed graph for the equivalence test only.

`meson setup <builddir> <srcdir>` keeps upstream argument order. There is no CMake front end, and the executor is not a Windows design.
