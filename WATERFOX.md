# Laputa Waterfox Architecture

This document records the current Waterfox-on-Laputa design. It is not a stage
plan. The stage sequence was useful while proving the stack, but the durable
architecture is now two desktop proof images, backed by one native build base:

- `laputa-bootstrapped-build-essential-native`: the reusable native package-build base.
- `laputa-dwl-foot-minimal-proof`: the minimal Wayland compositor and terminal
  environment.
- `laputa-waterfox-proof`: the complete browser session environment.

## Intent

The Waterfox proof exists to keep Laputa honest about desktop userspace. A
modern browser is large enough to expose missing kernel interfaces, device
manager assumptions, dynamic linker problems, certificate handling, input
plumbing, graphics policy, and session startup behavior.

The proof deliberately avoids the conventional desktop platform stack:

- no systemd, elogind, DBus, portals, PipeWire, PulseAudio, X11, XCB, GLX, or
  Xwayland;
- no udev daemon dependency;
- no Python in the target runtime;
- no shell-first session manager;
- no package dependency on a single monolithic desktop framework.

The accepted shape is a small Wayland session built from explicit packages and
XSH-owned startup code.

## Native Base

`make build-essential-native` builds `laputa-bootstrapped-build-essential-native`.
This is the shared scratch package-built toolchain and binary repository used
by the desktop proof images. It contains musl, LLVM, pkgconf, samurai, CMake,
m4, flex, bison, muon, and the combined `linux` package.

The `linux` package owns both the boot kernel and kernel UAPI headers. There is
no separate header package in the Waterfox build chain. Packages such as DRM,
input, ALSA, Mesa, seat, and PAM depend on `linux` when they need those
headers.

`make proof-kernel` copies the already-built `linux` tarball out of
`$(PACKAGE_TOOLS_IMAGE)` and extracts `boot/vmlinuz` for `boot.xsh`.
Browser package iteration should not rebuild Linux. The active Waterfox QEMU
proof is arm64; amd64 package work is tracked through `world-plan --arch
x86_64`, but the Linux package still needs x86_64 native Kbuild support before
an amd64 boot proof can consume it.

## Proof Images

`make dwl-foot-minimal-test` builds `laputa-dwl-foot-minimal-proof` from
[Dockerfile.dwl-foot-minimal](/Users/josh/d/laputa-systems/laputa/Dockerfile.dwl-foot-minimal:1)
and verifies it with
[proof-dwl-foot-minimal.xsh](/Users/josh/d/laputa-systems/laputa/proof-dwl-foot-minimal.xsh:1).

That image proves the non-browser desktop base:

- Wayland client/server libraries and protocol XML;
- `libxkbcommon` plus `xkeyboard-config`;
- `libudev-zero` as the `libudev.so.1` provider;
- `mdevd` plus Laputa's tiny `mdev.conf`;
- `libdrm`, `hwdata`, and `libdisplay-info`;
- `libevdev`, `mtdev`, `libinput`, `libseat`, and `seatd`;
- `wlroots0.19-mesa`;
- `dwl-minimal`;
- `fontconfig`, Hack TTF, `fcft-minimal`, and `foot-minimal`.

`make waterfox-test` builds `laputa-waterfox-proof` from
[Dockerfile.waterfox](/Users/josh/d/laputa-systems/laputa/Dockerfile.waterfox:1)
and verifies it with
[proof-waterfox.xsh](/Users/josh/d/laputa-systems/laputa/proof-waterfox.xsh:1).

That image extends the minimal desktop base with:

- `ca-certificates`;
- `waterfox-bin`;
- `waterfox-dwl-session`;
- `alsa-lib`, `alsa-ucm-conf`, and `alsa-utils-minimal`;
- `wl-clipboard`, using the PM-provided core command links;
- `libva`, `mesa-minimal`, and `wlroots0.19-mesa`.

The full image is the normal Waterfox proof artifact. The minimal image remains
because it isolates the compositor, input, seat, and terminal contract from the
browser and Mesa payload.

## Installed Package Tree

This tree is generated from the package database in the final
`laputa-waterfox-proof` image. It is the installed package forest, not a recipe
sketch. It includes packages currently present in the rootfs package database,
including protocol/header packages that are still installed, and excludes
Docker host/build-image packages and proof overlay files not owned by `pm`.

Regenerate it with:

```sh
docker run --rm laputa-waterfox-proof /bin/xsh /usr/lib/pm/pm.xsh -- tree /rootfs /tmp/pm-tree-work /tmp/pm-tree-out
```

`(*)` marks a package that was already expanded earlier in the forest.

```text
alsa-ucm-conf
`-- alsa-lib
    `-- musl
alsa-utils-minimal
|-- musl (*)
|-- alsa-lib (*)
`-- libudev-zero
    `-- musl (*)
baselayout
linux
pixman-dev
`-- pixman
    `-- musl (*)
tllist
waterfox-dwl-session
|-- waterfox-bin
|   |-- musl (*)
|   `-- ca-certificates
|-- dwl-minimal
|   |-- musl (*)
|   |-- wlroots0.19-mesa
|   |   |-- musl (*)
|   |   |-- wayland-libs-server
|   |   |   |-- musl (*)
|   |   |   `-- libffi
|   |   |       `-- musl (*)
|   |   |-- wayland-libs-client
|   |   |   |-- musl (*)
|   |   |   `-- libffi (*)
|   |   |-- libdrm
|   |   |   |-- musl (*)
|   |   |   `-- libudev-zero (*)
|   |   |-- libxkbcommon
|   |   |   |-- musl (*)
|   |   |   `-- xkeyboard-config
|   |   |-- pixman (*)
|   |   |-- mesa-minimal
|   |   |   |-- musl (*)
|   |   |   |-- expat
|   |   |   |   `-- musl (*)
|   |   |   |-- zlib
|   |   |   |   `-- musl (*)
|   |   |   |-- libdrm (*)
|   |   |   |-- libva
|   |   |   |   |-- musl (*)
|   |   |   |   |-- libdrm (*)
|   |   |   |   `-- wayland-libs-client (*)
|   |   |   |-- wayland-libs-client (*)
|   |   |   |-- wayland-libs-server (*)
|   |   |   `-- libunwind
|   |   |       `-- musl (*)
|   |   |-- libudev-zero (*)
|   |   |-- libseat
|   |   |   `-- musl (*)
|   |   |-- libinput
|   |   |   |-- musl (*)
|   |   |   |-- libudev-zero (*)
|   |   |   |-- libevdev
|   |   |   |   `-- musl (*)
|   |   |   `-- mtdev
|   |   |       `-- musl (*)
|   |   `-- libdisplay-info
|   |       |-- musl (*)
|   |       `-- hwdata
|   |-- wayland-libs-server (*)
|   |-- libxkbcommon (*)
|   `-- libinput (*)
|-- seatd
|   |-- musl (*)
|   `-- libseat (*)
|-- mdevd
|   `-- musl (*)
|-- libudev-zero (*)
|-- ca-certificates (*)
`-- foot-minimal
    |-- musl (*)
    |-- wayland-libs-client (*)
    |-- wayland-libs-cursor
    |   |-- musl (*)
    |   `-- wayland-libs-client (*)
    |-- libxkbcommon (*)
    |-- pixman (*)
    |-- fontconfig
    |   |-- musl (*)
    |   |-- freetype
    |   |   |-- musl (*)
    |   |   |-- zlib (*)
    |   |   `-- libpng
    |   |       |-- musl (*)
    |   |       `-- zlib (*)
    |   `-- expat (*)
    |-- fcft-minimal
    |   |-- musl (*)
    |   |-- fontconfig (*)
    |   |-- freetype (*)
    |   `-- pixman (*)
    `-- font-ttf-hack
wayland-dev
|-- expat (*)
|-- wayland-libs-client (*)
|-- wayland-libs-server (*)
`-- wayland-libs-cursor (*)
wayland-protocols
wl-clipboard
|-- musl (*)
`-- wayland-libs-client (*)
```

## Runtime Shape

The browser session is started by `waterfox-dwl-session`, installed by the
`waterfox-dwl-session` package. The init hook starts it detached in a new
session so the boot path can continue while the graphical proof runs.

The session exports a small, explicit environment:

- `XDG_RUNTIME_DIR=/run/user/1000`;
- `WAYLAND_DISPLAY=wayland-0`;
- `WLR_RENDERER=pixman` for the default browser proof;
- `MOZ_ENABLE_WAYLAND=1`;
- `NO_AT_BRIDGE=1`;
- `MOZ_DISABLE_AUTO_SAFE_MODE=1`;
- `MOZ_CRASHREPORTER_DISABLE=1`;
- `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`.

Startup is explicit and mode-specific:

1. populate `/dev` through `mdevd` and coldplug;
2. prepare `/run/user/1000` and console permissions;
3. start `seatd`;
4. enter the unprivileged `laputa` session through `su`;
5. start `dwl`;
6. in browser mode, start Waterfox on `about:blank`;
7. in clipboard mode, wait for `wayland-0`, run the Wayland clipboard helper,
   and terminate `dwl` so the next compositor proof can own DRM cleanly;
8. in terminal/debug modes, start `foot`.

`laputa` is a member of the `video`, `input`, `seat`, `audio`, and `tty` groups.
The session does not start DBus, a portal service, PipeWire, PulseAudio,
Xwayland, or a login manager.

## Device Layer

Laputa's current device model is:

- `mdevd` for `/dev` population and coldplug;
- a Laputa-owned `mdev.conf` for DRM, input, ALSA, and required hooks;
- `libudev-zero` as a daemonless `libudev.so.1` compatibility provider.

This preserves the useful `libudev` ABI without accepting systemd-udevd or eudev
as the device manager. The package graph has no consumer of `eudev-lite`; the
old recipe may remain only as a comparison or migration artifact.

`mdevd` and `libudev-zero` are still C components. Their current role is
acceptable for the proof, but the long-term Laputa direction is a memory-safe,
Laputa-owned replacement for this privileged device layer.

## Graphics

The default browser proof uses pixman wlroots. This is the conservative runtime:
it proves DRM, input, seat management, Wayland, dwl, foot, and Waterfox without
introducing EGL, GLES, GBM, Vulkan, GLX, X11, XCB, or VA-API into the default
session path.

The full Waterfox image also includes `mesa-minimal`, `libva`, and
`wlroots0.19-mesa` so the accelerated compositor path can be tested from the
same final artifact. The Mesa profile enables EGL/GLES/GBM and VA-API while
still forbidding GLX, X11, XCB, Vulkan, DBus, PipeWire, PulseAudio, portals, and
Xwayland.

VA-API remains target-specific. Generic arm64 QEMU can prove dependency closure
and compositor startup. Hardware decode belongs in a target-specific profile
with a real supported GPU and driver.

## Audio And Clipboard

Audio is intentionally ALSA-only:

- `alsa-lib`;
- `alsa-ucm-conf`;
- `alsa-utils-minimal`, limited to `alsactl`, `amixer`, and `aplay`.

The proof rejects PulseAudio and PipeWire. ALSA is enough to prove the kernel
sound path, userland library, UCM data, and basic tools without accepting a
desktop audio server.

Clipboard support is Wayland-native:

- `wl-clipboard`;
- PM-provided core command links used by the `wl-paste` default transfer path;
- `waterfox-session-clipboard-proof` for session-level validation.

The proof rejects DBus and portals for clipboard integration.

## Build Policy

The Waterfox proof stack is intentionally small but not toy-like. Packages may
use CMake/samu or Meson/muon when those are the upstream build systems and the
dependency boundary remains acceptable.

Package proofs start from `laputa-bootstrapped-build-essential-native`, which
provides the native C/C++/Meson/CMake toolchain and the cached PM repo. The
proof image should rebuild the package under test and its local proof-specific
package set, not the native base.

For foundational leaf packages, Laputa prefers native XSH package recipes over
upstream `./configure` and `make`. The current Waterfox runtime path builds
`libffi`, `mtdev`, `libudev-zero`, and `mdevd` plus private static `skalibs`
through XSH-native recipes. Some generated configuration is still
Linux/musl/arm64-shaped because the active browser VM proof is arm64.

`mdevd` still uses upstream `skalibs` shell generator scripts for generated
headers, but it does not run upstream `./configure` or invoke upstream `make`.

## Proof Commands

Static image proofs:

```sh
make dwl-foot-minimal-test
make waterfox-test
```

QEMU proofs:

```sh
make dwl-foot-minimal-qemu-debug
make waterfox-qemu-test
```

`make waterfox-qemu-test` is the single final Waterfox VM proof. It boots the
final Waterfox image once and proves ALSA, evdev/libinput, Mesa/wlroots, Wayland
clipboard, browser startup, QMP input injection, and the host-side screenshot
check in the same run. The target uses the packaged proof kernel; if the local
artifact is missing, it runs `make proof-kernel` to copy it from the native
base. Waterfox package changes should not cause Linux to rebuild.

`make boot` starts the minimal dwl/foot image interactively by default. Override
`XSH_BOOT_ROOTFS_IMAGE` to boot another proof image.

## Current Build Debt

The proof is correct but not yet incremental enough. The Waterfox Dockerfile
still installs the browser-session package set through large `pm
build-install` layers. A change to a late package such as
`waterfox-dwl-session` can invalidate that layer and rebuild local desktop
packages inside the image. That is Docker/package-layer churn, not a native
base or Linux kernel rebuild, but it is the next obvious ergonomics problem for
this proof.

## Boundaries

The Waterfox package is not the operating system. It is a pressure test for the
operating system:

- browser packaging proves dynamic linking and private bundled dependencies;
- the session package proves init hooks, environment setup, and process
  supervision;
- the compositor proof proves DRM/input/seat/Wayland without a desktop bus;
- the audio and clipboard proofs cover practical user workflows without
  importing desktop middleware;
- the Mesa proof covers accelerated graphics without accepting X compatibility
  layers.

Future work belongs in the architecture only when it changes one of those
contracts. Iteration checklists belong in issue threads or separate planning
documents, not here.
