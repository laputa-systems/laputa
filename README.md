# Laputa

Laputa is a small Linux distribution (musl, aarch64 and x86_64) whose package
manager, recipes, init system, installer, and system tooling are written in
XSH. This monorepo builds the whole distribution from pinned
upstream sources on one machine: it fetches every input once, then builds
offline in Docker and publishes to a mirror on the loopback interface. It never
contacts a remote Laputa mirror.

Laputa and XSH are developed together. XSH lives in its own checkout at
`../xsh` (`XSH_ROOT`), and every Laputa seed is built from that checkout.
Changes to XSH that make Laputa simpler are welcome. Make them there, then run
`make seed` to bring them into the build.

## Layout

| Path | Owns |
|---|---|
| `pm.xsh`, `pm/` | the package manager |
| `packages/<name>/` | package recipes (`PKGBUILD.xsh`), proofs, package files |
| `seed/`, `Dockerfile.package-tools`, `bootstrap-llvm-seed.xsh` | the XSH seed, the build images, and the world commands behind `make plan/build/publish/root` |
| `mirror/` | the package mirror server (a host tool, not a package) |
| `xinit/` | `xinit.xsh`, the PID 1 and service manager |
| `system/`, `laputa.xsh`, `profiles/`, `guest/`, `boot/` | the `qemu-dwl-foot` profile CLI and its QEMU proof |
| `installer/`, `build-installer-*.xsh`, `installer-*.xsh` | the installer image and its QEMU harness |
| `tests/` | native XSH test suites |
| `docs/` | [development](docs/DEVELOPMENT.md), [PM](docs/PM.md), [QEMU](docs/QEMU.md) and infrastructure notes |

`AGENTS.md` lists every make target.

## Prerequisites

On a Linux host (aarch64 or x86_64) you need only `git`, `make`, Docker
(the daemon running and usable by your user), and network access for the
fetch steps. You don't need a Rust toolchain or a pre-built XSH. `make
host-xsh` builds static XSH binaries and `make mirror` builds the mirror, both
in XSH's own build image.

On macOS (Apple Silicon), the developer path uses XSH's native release build
(`cargo build --release` in `../xsh`) and runs the mirror through `cargo`.
Docker runs `linux/arm64` (OrbStack).

## Build from a fresh Linux host

```sh
git clone https://github.com/laputa-systems/laputa.git
git clone https://github.com/laputa-systems/xsh.git    # beside laputa: ../xsh
cd laputa
make host-xsh        # networked once: xsh-test image, XSH crates; then static xsh/xshi/xsht in .out/host/<arch>/
make fetch           # the networked step: every pinned source, the crates, the host-tools base image
make seed            # offline: the XSH seed in .out/seed/<arch>/, then the package-tools image
make mirror &        # http://127.0.0.1:3000, data in .out/mirror (the first run builds the mirror)
make build           # offline: every package, in Docker with --network none
make publish         # the same plan's artifacts into the local mirror
make root PKGS="baselayout xsh xinit musl"   # import from the mirror, compose a root, check it runs
kill %1              # stop the mirror
```

`ARCH` defaults to the host's architecture, and the package build runs
natively in Docker. `make build STOP=pre-cmake` builds only the packages that
need neither cmake nor linux, and `PKGS="a b"` builds those packages and their
dependencies. A rebuild with nothing changed reuses every artifact.

## Where state lives

| Path | Holds | Removed by |
|---|---|---|
| `.cache/sources/sha256/` | fetched upstream sources, by digest | `make distclean` |
| `.cache/cargo/`, `.cache/images/` | XSH and mirror crates, the saved host-tools base image | `make distclean` |
| `.out/host/<arch>/` | host `xsh`/`xshi`/`xsht` and `laputa-mirror` (Linux) | `make clean` |
| `.out/xsh-target/`, `.out/mirror-target/` | incremental cargo targets for the seed and host tools | `make clean` |
| `.out/seed/<arch>/` | the XSH seed and its manifest | `make clean` |
| `.out/artifacts/<arch>/` | the PM artifact store, which is the build cache | `make clean` |
| `.out/world/<arch>/` | the last plan and the `make root` tree | `make clean` |
| `.out/mirror/` | local mirror data | `make clean` |
| `target/` | profile and installer outputs | `make clean` |

`make clean` removes all derived state, including the `laputa-*` Docker
images. `make distclean` also removes `.cache/`, after which `make fetch` has
to download everything again. XSH's `xsh-test` image belongs to XSH, and both
targets leave it in place.
