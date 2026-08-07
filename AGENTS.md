# Agent Guide

This repository owns Laputa Linux integration: proof images, installer images,
QEMU harnesses, local Linux iteration helpers, Waterfox/XPS workflows, and the
reusable package-build Docker base.

Package manager code and package definitions live in the sibling package repo,
normally `~/d/laputa-systems/packages`. Override that path with `LAPUTA_PACKAGES_ROOT`
when using another checkout.
The sibling `~/d/laputa-systems/xinit` checkout is canonical for boot rootfs
assembly; override it with `XINIT_SOURCE_ROOT` when using another checkout.

## Output

- Do not narrate obvious tool use or repeat command output the user can already
  see.
- Summarize findings, decisions, and verification results.
- When reporting a failure, include the command and why it matters.

## Working Areas

- `Dockerfile.build-essential-native` and
  `Dockerfile.bootstrap-build-essential-native`: reusable package-build bases.
- `Dockerfile.proof-rootfs`, `Dockerfile.dwl-foot-minimal`, and
  `Dockerfile.waterfox`: image-level proofs.
- `boot.xsh` and `LINUX.md`: QEMU and Linux iteration/proof workflows.
- `build-installer-image.xsh`, `installer-qemu-test.xsh`,
  `installer-qemu-manual.xsh`, and `INSTALLER.md`: installer image workflows.
- `WATERFOX.md` and `XPS.md`: desktop/browser and hardware iteration notes.

For package rules, PM behavior, and package acceptance policy, read
`~/d/laputa-systems/packages/AGENTS.md`.

## World Builds

For operational details and failure playbooks, see `PLAYBOOK-WORLD-BUILD.md`.

Two world-build entry points exist:

### `make world-build` — Docker-based (macOS or any Docker host)

Runs PM inside a Docker container (`PACKAGE_TOOLS_IMAGE`) with
`--platform $(LAPUTA_DOCKER_PLATFORM)` (defaults to `linux/arm64`). Docker
handles architecture emulation via QEMU/binfmt transparently. Packages are
mounted read-only into the container. This is the only world-build path that
works on macOS.

`make world-build` downloads the pinned Linux `xsh`, `xshi`, and `xsht` release
assets from GitHub, verifies their checksums, and mounts them with the local
`core/` applets. The published XSH binaries are the execution environment.

### `make world-build-aarch64` — native cross-compilation (amd64 host only)

Runs PM directly on an amd64 host (threadripper) without Docker or QEMU/binfmt.
PM's native-cross mode (`XSH_PM_NATIVE_CROSS=1`) separates the build root
(x86_64 native tools) from the target root (aarch64 packages):

- `XSH_PM_ARCH=aarch64`
- `XSH_PM_BUILD_ARCH=x86_64`
- `XSH_PM_TARGET_ARCH=aarch64`
- `XSH_PM_NATIVE_CROSS=1`

Package builds receive `XSH_PM_BUILD_ROOT` so host helper tools (cc, ld.lld,
llvm-objcopy, flex, bison, etc.) resolve from the amd64 build root. The Linux
kernel package uses this for its native build helpers.

Parallelism defaults to `nproc` for `WORLD_JOBS`, `LINUX_KBUILD_JOBS`, and
`XSH_LINUX_KBUILD_DISCOVER_JOBS`. The kernel plan cache lives at
`XSH_LINUX_KBUILD_PLAN_CACHE_DIR` (defaults to
`~/.cache/laputa/linux-kbuild-aarch64`).

**Key constraint:** QEMU/binfmt must not be required for package compilation in
this path. QEMU is reserved for runtime validation after artifacts exist
(booting a rootfs, smoke-testing the kernel, exercising an installer image).

`make world-build-amd64` is a separate native (non-cross) amd64 path that
requires root for chroot and does not set any of the native-cross PM variables.

`make boot` and `make boot-userspace-e2e` install the local `xinit.xsh` from
`XINIT_SOURCE_ROOT` (defaulting to the sibling `xinit` checkout) after package
installation, so boot proofs use the current service manager without waiting
for a package release.

### Troubleshooting

**`PmError.DirtyFilesystem: <pkg> would overwrite unowned <path>`** — a stale
world-plan root from a prior interrupted or incomplete build. PM tracks file
ownership in `var/lib/xsh-pm/packages/*/manifest.json` within each root. When a
remote package's manifest includes a file that already exists on disk but isn't
tracked in that DB, `ensure_installable` raises `DirtyFilesystem`. Remote
chroot-base packages (`musl`, `zlib`, `llvm-toolchain`) are especially
susceptible because the cleanup pass (`remove_world_unowned_install_conflicts`)
only runs for locally-built packages, never for remote ones. Fix:

    rm -rf ~/.cache/laputa/world-*

Then re-run the world-build.

## Threadripper Notes

- The amd64 iteration host is `threadripper`, a native amd64 Alpine host for
  musl package work, native-cross world builds, Linux proofs, coverage, PGO,
  and benchmarks. Use an interactive bash session:
  `ssh -tt threadripper bash`. If the login shell reports that `bash` could not
  be executed, run `bash` at the remote prompt. Prefer interactive sessions;
  one-shot SSH commands can be parsed by the login shell before Bash starts.
- The remote Laputa checkout is `/home/josh/d/laputa-systems/laputa`; the
  remote package checkout should be `/home/josh/d/laputa-systems/packages`; the
  remote XSH checkout is `/home/josh/d/laputa-systems/xsh`.
- The canonical host XSH runner is
  `/home/josh/d/laputa-systems/xsh/target/debug/xsh`. Build it with the debug
  profile when needed and set `XSH_HOST` to that path; do not use an installed
  `/usr/local/bin/xsh` binary, which may be stale.
- Cargo is not on the default remote PATH. Use
  `/home/josh/.cargo/bin/cargo`. Do not build release XSH binaries there unless
  the user explicitly changes that rule.
- The host may have a sparse tool set. Prefer `rg` when available, use
  `GIT_PAGER=cat git --no-pager ...` if Git tries to use a missing pager, and
  expect to request small utilities when they materially improve debugging.
  Python, `patch`, and `git-lfs` may be missing; install them explicitly when
  they materially reduce risk. Initialize git-lfs in the checkout before
  touching XSH PGO profile data.
- Do not use Docker on `threadripper` for native package compilation, coverage,
  PGO, or benchmark work unless the user explicitly asks for a Docker
  comparison.
- If `github.com` stops resolving, check `/etc/resolv.conf`: Tailscale DNS may
  have overwritten it with `100.100.100.100`. `doas tailscale set
  --accept-dns=false` plus ordinary resolvers restored GitHub resolution on
  June 14, 2026.

## Writing XSH

The XSH language implementation lives in `~/d/laputa-systems/xsh`. Before writing
any `.xsh` script, always read the xsh agent guide and idioms:

- `~/d/laputa-systems/xsh/AGENTS.md` — agent guide for the xsh repo
- `~/d/laputa-systems/xsh/docs/IDIOMS.md` — canonical patterns (CLI parsing,
  error handling, pipelines, subprocess execution, net requests, filesystem ops)
- `~/d/laputa-systems/xsh/docs/AGENT-ROUTING.md` — task-to-file map for xsh
  internals (only needed when changing the language itself)

Key rules for writing xsh scripts in this repo:

- Use `#!/bin/xsh` as the shebang.
- `proc main(...argv: List[Str]) [fs, process, error]` with `main(@args)?` for
  CLI scripts. Add `net` to the effect list when using `net.request` or
  `net.download`.
- `run.text <command> <args...> ?` captures stdout; `run <command> <args...>`
  runs without capture. Both need the `process` effect.
- `net.request({method: "GET", url})?` returns `{body: Bytes, status: Int, ...}`.
  Convert body with `.body.utf8()?`. `net.download({method: "GET", url, dest:
  Path})?` streams to disk.
- `fs.read_text(path)?` and `fs.write(path, data)?` for file I/O. Paths are
  `fp"..."` literals; `Path` values cannot be interpolated in f-strings — use
  fixed path strings instead.
- `hash.sha256(path)?.hex()` to compute SHA256 of a file.
- `regex.compile("pattern")?` returns a regex; `.captures(str)` returns capture
  groups as a list.
- Anonymous record types (`{a: Str, b: Str}`) are valid in values and `type`
  definitions, but NOT in proc parameter or return type annotations — define a
  named `type` first.
- `let` bindings are immutable; use `var` when reassignment is needed.
- `if` expressions require `else`. Use `match` for multi-way branching on a
  single value.
- `pure` functions (no effects) can be called from any proc. Procs declare
  effects explicitly in brackets.
- `?` propagates errors from `Result`-returning calls. It works inside procs
  that return `Result` or have the `error` effect.
- `fs.tempdir()?` returns a `Path` but `Path` cannot be interpolated in
  f-strings and the current release binary lacks `.display()`. Use a fixed
  `/tmp/xsh-...` prefix for temp files, or `net.request` (which returns body
  in memory) for small downloads to avoid temp files entirely.
- Test small xsh snippets with `xsh script.xsh -- args`. The `--` separates
  xsh flags from script arguments.


## Rules

- Keep changes scoped to the requested behavior.
- Preserve comments that explain why something exists.
- Do not add dependencies unless there is a clear need and no local equivalent.
- Do not run pre-commit hooks. Do not push.
- Do not build release XSH binaries in this repository. Consume published XSH
  release artifacts instead.

## Verification

Choose the narrowest useful proof first. For integration changes, prefer script
entrypoint checks, then the affected Docker image proof, then QEMU. Package
checks are run from this repo through `LAPUTA_PACKAGES_ROOT`, for example
`make package-test PKGNAME=<name>`.

## Local Development

Use the checked-out package repo by default. `make package-test` and
`make world-build` download and mount the pinned Linux XSH release binaries and
local `core/` applets before invoking PM inside Docker. This keeps the
package-tools image as bootstrap state while using the published execution
binaries.

On macOS, Docker/OrbStack is required for Linux target binaries and package
proofs. A host-native XSH binary is enough to run scripts, but it is not a
target rootfs binary. For installer overlays, `LAPUTA_LOCAL_PM_REPO=file://...`
points `build-installer-image.xsh` at a local package repo that is installed
after the remote base packages. Prefer building that repo with PM targets over
hand-assembled tarballs.

For installer iteration:

- `make installer-image-aarch64` builds the default local installer image.
- `make installer-qemu-test-aarch64` runs the automated QEMU smoke path.
- `LAPUTA_LOCAL_PM_REPO=file:///tmp/repo` overlays locally built packages.

For rootfs changes, run `make proof-rootfs`. For Linux package iteration, use
the package repo path plus `make amd64-package-test PKGNAME=linux` or the
targeted `linux-amd64-*` helpers. For installer changes, run the narrow image
builder or QEMU target that matches the touched behavior.

## CI Workflows

- `.github/workflows/laputa-validate.yml`: fast integration script checks using
  the published XSH release.
- `.github/workflows/laputa-bootstrap-*.yml` and
  `.github/workflows/laputa-bootstrapped-arm64.yml`: recovery and reusable
  build-base workflows. They may checkout the package repo for package inputs.
- Normal package publishing lives in `laputa-systems/packages`.
