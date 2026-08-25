# XPS 13 9343 Hardware Profile

This tracks the Dell XPS 13 9343 path for running Laputa on real x86_64
hardware. The expected graphics target is Intel Broadwell/i915 with Mesa iris
for EGL/GLES/GBM and Wayland.

`mesa-minimal` remains the fast proof package. It is useful for dependency
closure and QEMU compositor smoke tests, but it is not a real hardware driver.
The XPS path must use a separate source-built Mesa package once the Mesa build
tool prerequisites are available.

## Target Runtime

The first real-hardware profile should provide:

- the x86_64 Laputa kernel with EFI boot, i915 DRM/KMS, evdev, I2C HID,
  multitouch HID, ACPI video, backlight, simpledrm, firmware loading, NVMe,
  USB HID, Intel HDA audio, Intel Wi-Fi, and Dell laptop platform support;
- `/dev/dri/card0` and `/dev/dri/renderD128` populated by the device layer;
- `seatd`, `libseat`, `libudev-zero`, `libinput`, `dwl`, and the existing
  Wayland compositor and terminal session;
- Mesa EGL/GLES/GBM with `/usr/lib/dri/iris_dri.so`;
- a software fallback DRI driver, preferably `swrast_dri.so`;
- no GLX, X11, XCB, Vulkan, OpenCL, desktop tools, tests, demos, or docs in the
  first hardware profile.

VA-API is intentionally separate. Broadwell browser video decode should be
tracked after the display/compositor path works, likely through an Intel VA
driver package installed beside `libva`.

## Completed Preliminary Work

- `xps-preflight.xsh` defines the live target-side hardware contract.
  Run it from the checkout on the booted laptop after installing the XPS
  profile:

  ```sh
  xsh xps-preflight.xsh -- /
  ```

- The `linux` package proof now checks the x86_64 kernel config for the XPS
  display, input, storage, audio, Wi-Fi, and Dell platform basics:

  - `CONFIG_DRM`
  - `CONFIG_DRM_KMS_HELPER`
  - `CONFIG_DRM_I915`
  - `CONFIG_DRM_SIMPLEDRM`
  - `CONFIG_FW_LOADER`
  - `CONFIG_INPUT_EVDEV`
  - `CONFIG_I2C_HID`
  - `CONFIG_HID_MULTITOUCH`
  - `CONFIG_ACPI_VIDEO`
  - `CONFIG_BACKLIGHT_CLASS_DEVICE`
  - `CONFIG_BLK_DEV_NVME`
  - `CONFIG_USB_XHCI_HCD`
  - `CONFIG_USB_HID`
  - `CONFIG_SND_HDA_INTEL`
  - `CONFIG_IWLWIFI`
  - `CONFIG_IWLMVM`
  - `CONFIG_CFG80211`
  - `CONFIG_MAC80211`
  - `CONFIG_DELL_LAPTOP`
  - `CONFIG_DELL_WMI`
  - `CONFIG_DELL_SMBIOS`

- The current `kernel-x86_64.config` carries the
  `profiles/dell-xps-13-9343.config` requirements directly until kernel config
  composition exists.

- `mesa-minimal` is unchanged and remains the fast QEMU/proof path.

- `make installer-image-aarch64` and `make installer-image-amd64` are separate
  targets. The amd64 target emits an x86_64 hybrid ISO installer artifact with
  the UEFI fallback path `EFI/BOOT/BOOTX64.EFI`.

## Mesa Package Boundary

Create the real package as `mesa-intel` rather than replacing `mesa-minimal`.
That keeps fast proof images cheap and gives the real hardware path an explicit
capability name.

Use Mesa `24.2.8` initially, matching `mesa-minimal`.

Source:

```text
https://archive.mesa3d.org/mesa-24.2.8.tar.xz
sha256: 999d0a854f43864fc098266aaf25600ce7961318a1e2e358bff94a7f53580e30
```

Runtime deps:

```text
musl
expat
libdrm
libffi
wayland-libs-client
wayland-libs-server
zlib
```

Build deps:

```text
llvm-toolchain
linux
muon
pkgconf
flex
bison
expat
libdrm
libffi
wayland-dev
zlib
python3
python-mako
python-pyyaml
```

The Python dependencies are build-root tools, not runtime deps. They should be
real Laputa packages before `mesa-intel` is added to `~/d/laputa-systems/packages/repo`, otherwise
PM would either miss required build tools or break whole-world planning on
nonexistent packages.

The intended Mesa setup is:

```text
-Dprefix=/usr
-Dlibdir=lib
-Ddefault_library=shared
-Dbuildtype=release
-Dplatforms=wayland
-Degl-native-platform=wayland
-Degl=enabled
-Dgbm=enabled
-Dgles1=disabled
-Dgles2=enabled
-Dopengl=false
-Dglx=disabled
-Dglvnd=disabled
-Dgallium-drivers=iris,swrast
-Dvulkan-drivers=
-Dllvm=enabled
-Dshared-llvm=enabled
-Dgallium-vdpau=disabled
-Dgallium-va=disabled
-Dgallium-xa=disabled
-Dgallium-opencl=disabled
-Dgallium-rusticl=false
-Dtools=
-Dbuild-tests=false
-Denable-glcpp-tests=false
-Dinstall-intel-gpu-tests=false
-Dhtml-docs=disabled
-Dvalgrind=disabled
-Dlibunwind=disabled
-Dlmsensors=disabled
-Dxmlconfig=disabled
```

The package proof should require:

- package metadata for `mesa-intel`;
- `libEGL.so.1`, `libGLESv2.so.2`, and `libgbm.so.1`;
- `/usr/lib/dri/iris_dri.so`;
- `/usr/lib/dri/swrast_dri.so`;
- no `libGLX.so.0`;
- no `libvulkan.so.1`.

## Integration Plan

1. Add build-tool packages for `python3`, `python-mako`, and `python-pyyaml`, or
   a narrowly scoped native build-tools package that provides exactly those
   staged tools.
2. Add `mesa-intel` under `~/d/laputa-systems/packages/repo` with the package boundary above.
3. Add `wlroots0.19-intel` or another explicit XPS compositor profile that
   depends on `mesa-intel`. Do not change `wlroots0.19-mesa` until the real
   Mesa package is proved.
4. Add an XPS rootfs/image profile that installs `mesa-intel`, the compositor
   profile and the current Wayland session.
5. Build and upload the amd64 packages.
6. Build the amd64 installer ISO:

   ```sh
   make installer-image-amd64
   ```

7. Boot the XPS 13 9343 and run `xps-preflight.xsh`.
8. Start `dwl` with `WLR_RENDERER=gles2` and verify Mesa loads `iris_dri.so`.

## Hardware Test Checklist

On the laptop, collect these before debugging compositor behavior:

```sh
dmesg | grep -iE 'i915|drm|firmware'
ls -l /dev/dri
cat /sys/class/drm/card0/device/vendor
cat /sys/class/drm/card0/device/device
```

Expected first-pass result:

- i915 binds to the Intel GPU;
- `/dev/dri/card0` and `/dev/dri/renderD128` exist;
- the `laputa` user can access the render node through seat/device policy;
- `xps-preflight.xsh` passes;
- `dwl` starts with `WLR_RENDERER=gles2`;

## Open Work

- Package Python/Mako/PyYAML as staged build tools for Mesa.
- Add and prove `mesa-intel`.
- Add an explicit XPS compositor/rootfs profile.
- Add the VA-API driver only after the basic display path works.
