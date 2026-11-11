# Architecture

Workspace members are listed in [`Cargo.toml`](../Cargo.toml).

- `crates/graph` holds `State`, `Rule`, and `Edge`.
- `crates/state` owns `.ninja_log` and `.ninja_deps`.
- `crates/ninja` parses the manifest, schedules edges, and runs them. This is the build users run.
- `crates/meson` is the Meson front end. Setup writes `build.ninja` and `meson-info/`. Compile and test invoke `ninja` from `PATH`. Setup also records the install plan in `meson-private/install_plan.json`; install rebuilds with `ninja`, copies it into `DESTDIR` + prefix without a shell, strips when configured, and rewrites ELF RPATH/RUNPATH in process.
- `crates/engine` is a queue helper (`QueueScheduler`). It is not the executor, and no binary depends on it. It does not depend on Meson semantics.
- `bins/meson`, `bins/ninja`, and `bins/build` are wrappers. `gluon-build meson` builds a fresh argument list. `gluon-build ninja` calls `ninja::main_entry`, which reads the process arguments again.

`build.ninja` is the interchange file. User builds run through `crates/ninja`.

`meson setup <builddir> <srcdir>` keeps upstream argument order. There is no CMake front end, and the executor is not a Windows design.
