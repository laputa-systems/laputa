##! Package recipe metadata and build operations.
use pm.env as pm_env

## Package recipe export.
export const name = "wayland-protocols"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.49"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export let deps = []

## Package recipe export.
export const mkdeps_host = ["muon", "pkgconf", "wayland-dev"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/VERSION/downloads/wayland-protocols-VERSION.tar.xz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "ec4c8f74942d6dff7ace8b4ce4764f0ef9ff618a935d974ea77edee2ad240b14",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/share/pkgconfig/wayland-protocols.pc",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/stable/linux-dmabuf/linux-dmabuf-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/stable/presentation-time/presentation-time.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/stable/tablet/tablet-v2.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/stable/viewporter/viewporter.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/alpha-modifier/alpha-modifier-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/color-management/color-management-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/color-representation/color-representation-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/commit-timing/commit-timing-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/content-type/content-type-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/drm-lease/drm-lease-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-background-effect/ext-background-effect-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-data-control/ext-data-control-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-idle-notify/ext-idle-notify-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-image-capture-source/ext-image-capture-source-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-transient-seat/ext-transient-seat-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/ext-workspace/ext-workspace-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/fifo/fifo-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/fractional-scale/fractional-scale-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/pointer-warp/pointer-warp-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/security-context/security-context-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/single-pixel-buffer/single-pixel-buffer-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/tearing-control/tearing-control-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/xdg-dialog/xdg-dialog-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/xdg-session-management/xdg-session-management-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/xdg-system-bell/xdg-system-bell-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/xdg-toplevel-drag/xdg-toplevel-drag-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/fullscreen-shell/fullscreen-shell-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/input-method/input-method-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/input-timestamps/input-timestamps-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/linux-explicit-synchronization/linux-explicit-synchronization-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/pointer-gestures/pointer-gestures-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/primary-selection/primary-selection-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/tablet/tablet-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/tablet/tablet-unstable-v2.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/text-input/text-input-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/text-input/text-input-unstable-v3.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/xdg-foreign/xdg-foreign-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/xdg-foreign/xdg-foreign-unstable-v2.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/xdg-shell/xdg-shell-unstable-v5.xml",
    kind: "file",
  },
  {
    path: p"usr/share/wayland-protocols/unstable/xdg-shell/xdg-shell-unstable-v6.xml",
    kind: "file",
  },
]

error WaylandProtocolsError = Patch(message: Str)

proc replace_required(file: Path, old: Str, new: Str) [fs, error] {
  let text = fs.read_text(file)?

  if old not in text {
    return Err(WaylandProtocolsError.Patch(f"{file} no longer holds the patched block"))?
  }

  fs.write(file, text.replace(old, new))?
}

# The package ships protocol XML only. When it finds wayland-scanner, upstream
# generates and installs a C header per protocol; consumers run the scanner
# themselves, so drop the scanner lookup and the generated headers.
proc patch_generated_header_install() [fs, error] {
  let build_file = p"meson.build"

  replace_required(
    build_file,
    """dep_scanner = dependency('wayland-scanner',
    version: get_option('tests') ? '>=1.25.0' : '>=1.22.90',
    required: get_option('tests'),
    native: true,
    fallback: 'wayland'
)
if dep_scanner.found()
	prog_scanner = find_program(dep_scanner.get_variable(pkgconfig: 'wayland_scanner', internal: 'wayland_scanner'))
endif
""",
    "",
  )?

  replace_required(
    build_file,
    """include_dirs = []
headers = []
if dep_scanner.found()
	subdir('include/wayland-protocols')
	include_dirs = ['include']
endif""",
    """include_dirs = []
headers = []""",
  )?
}

proc prune_x_compat_protocols(root: Path) [fs, error] {
  fs.remove(fp"{root}/usr/share/wayland-protocols/staging/xwayland-shell/xwayland-shell-v1.xml", missing_ok: true)?
  fs.remove(fp"{root}/usr/share/wayland-protocols/staging/xwayland-shell", missing_ok: true)?

  fs.remove(
    fp"{root}/usr/share/wayland-protocols/unstable/xwayland-keyboard-grab/xwayland-keyboard-grab-unstable-v1.xml",
    missing_ok: true,
  )?

  fs.remove(fp"{root}/usr/share/wayland-protocols/unstable/xwayland-keyboard-grab", missing_ok: true)?
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let muon = process.which("muon")?
  let pc = pm_env.pkg_config_context()?
  patch_generated_header_install()?

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon "setup" pm_env.meson_prefix_arg() "-Dtests=false" "build" ?

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install ?
    }?
  }?

  prune_x_compat_protocols(dest)?
}
