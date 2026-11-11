# Status

User builds run through `crates/ninja`. `crates/engine` is not on that path. Snapshot persistence, `QueueScheduler`, and `Interner` are not wired into dispatch.

Open defects are in [TODO.md](../TODO.md).

Releases: CI and `workflow_dispatch` build the `dist` profile for `aarch64-apple-darwin` and `x86_64-unknown-linux-musl` and publish `release-<sha>` prereleases. From `~/usr`, install with `sh sync tools gluon`. From `~/d/view`, install with `make toolchain`.
