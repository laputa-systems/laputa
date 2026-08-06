error ProofError = Failed(kind: Str, message: Str)

type PrivateNeededModule = module {
  export proc verify_private_needed(root: Path, allowed_external_sonames: Path, private_library_root: Path) [fs, error] -> Result[Record]
}

pure required_packages() -> List[Str] {
  [
    "alsa-lib",
    "alsa-ucm-conf",
    "alsa-utils-minimal",
    "ca-certificates",
    "dwl-minimal",
    "foot-minimal",
    "laputa-pm",
    "libudev-zero",
    "libva",
    "mdevd",
    "mesa-minimal",
    "seatd",
    "waterfox-bin",
    "waterfox-dwl-session",
    "wl-clipboard",
    "wlroots0.19-mesa",
  ]
}

pure forbidden_package_terms() -> List[Str] {
  [
    "dbus",
    "DBus",
    "eudev",
    "gtk",
    "GTK",
    "libGLX",
    "libX11",
    "libxcb",
    "pipewire",
    "PipeWire",
    "portal",
    "PulseAudio",
    "pulseaudio",
    "systemd",
    "vulkan",
    "Vulkan",
    "x11",
    "X11",
    "xcb",
    "XCB",
    "xwayland",
    "Xwayland",
  ]
}

pure forbidden_needed_terms() -> List[Str] {
  ["libGLX", "libX11", "libxcb", "libdbus", "libpipewire", "libpulse", "libvulkan"]
}

proc ensure(condition: Bool, kind: Str, message: Str) [error] {
  if ! condition {
    return Err(ProofError.Failed(kind, message))
  }
}

proc verify_package_present(root: FsRoot, name: Str) [fs, error] {
  ensure(
    fs.root_exists(root, fp"var/lib/xsh-pm/packages/${name}")?,
    "waterfox-package",
    f"missing installed package ${name}",
  )?
}

proc verify_packages(rootfs: Path, root: FsRoot) [fs, error] {
  let db = fp"${rootfs}/var/lib/xsh-pm/packages"
  ensure(fs.root_exists(root, p"var/lib/xsh-pm/packages")?, "waterfox-package-db", "missing package database")?

  for name in required_packages() {
    verify_package_present(root, name)?
  }

  for entry in fs.ls(db)? |> where .kind == "dir" {
    for term in forbidden_package_terms() {
      ensure(! (term in entry.name), "waterfox-package", f"forbidden package installed: ${entry.name}")
    }
  }
}

proc verify_file(root: FsRoot, relative: Path, kind: Str) [fs, error] {
  ensure(fs.root_exists(root, relative)?, kind, f"missing ${relative.display()}")?
}

proc verify_executable(root: FsRoot, relative: Path, kind: Str) [fs, error] {
  ensure(fs.root_metadata(root, relative)?.executable, kind, f"missing executable ${relative.display()}")?
}

proc readelf_path() [fs, process, error] -> Result[Path] {
  if fs.exists(/build-env/usr/bin/readelf)? {
    return /build-env/usr/bin/readelf
  }

  process.which("readelf")?
}

proc needed_entries(path_value: Path) [fs, process, error] -> Result[List[Str]] {
  let readelf = readelf_path()?
  let out = run.text $readelf "-d" $path_value ?
  var entries: List[Str] = []

  for line in out.split("\n") {
    if "NEEDED" in line {
      for term in forbidden_needed_terms() {
        ensure(! (term in line), "waterfox-needed", f"${path_value.display()} needs forbidden ${line.trim()}")
      }

      let left = line.split("[")
      ensure(left.len() > 1, "waterfox-needed", f"could not parse ${line.trim()}")?
      let right = left[1].split("]")
      ensure(right.len() > 0, "waterfox-needed", f"could not parse ${line.trim()}")?
      entries = entries.push(right[0])
    }
  }

  entries
}

proc verify_needed(path_value: Path, required: List[Str]) [fs, process, error] {
  let entries = needed_entries(path_value)?
  ensure(entries.len() > 0, "waterfox-needed", f"${path_value.display()} has no dynamic dependencies")?

  for soname in required {
    ensure(soname in entries, "waterfox-needed", f"${path_value.display()} missing ${soname}")
  }
}

proc verify_ca_certificates(root: FsRoot) [fs, error] {
  verify_file(root, p"etc/ssl/certs/ca-certificates.crt", "waterfox-ca")?
  verify_executable(root, p"usr/bin/update-certdata", "waterfox-ca-helper")?

  ensure(
    "-----BEGIN CERTIFICATE-----" in fs.root_read_text(root, p"etc/ssl/certs/ca-certificates.crt")?,
    "waterfox-ca",
    "CA bundle does not contain a PEM certificate",
  )
}

proc verify_waterfox_metadata(root: FsRoot) [fs, error] {
  verify_file(root, p"opt/waterfox/application.ini", "waterfox-metadata")?
  let body = fs.root_read_text(root, p"opt/waterfox/application.ini")?
  ensure("Name=Waterfox" in body, "waterfox-metadata", "application.ini does not identify Waterfox")?
  ensure("Version=140.11.0" in body, "waterfox-metadata", "application.ini has unexpected Waterfox version")?
}

proc verify_groups(root: FsRoot) [fs, error] {
  let group_text = fs.root_read_text(root, p"etc/group")?

  for group_name in ["video", "input", "seat", "audio", "tty"] {
    var matched = false

    for line in group_text.lines() {
      if line.starts_with(f"${group_name}:") and "laputa" in line {
        matched = true
      }
    }

    ensure(matched, "waterfox-group", f"laputa is not a member of ${group_name}")?
  }
}

proc verify_session_script(root: FsRoot) [fs, error] {
  let script = fs.root_read_text(root, p"usr/bin/waterfox-dwl-session")?

  for term in [
    "XDG_RUNTIME_DIR = \"/run/user/1000\"",
    "WAYLAND_DISPLAY = \"wayland-0\"",
    "WLR_RENDERER = \"pixman\"",
    "MOZ_ENABLE_WAYLAND = \"1\"",
    "NO_AT_BRIDGE = \"1\"",
    "MOZ_DISABLE_AUTO_SAFE_MODE = \"1\"",
    "MOZ_CRASHREPORTER_DISABLE = \"1\"",
    "SSL_CERT_FILE = \"/etc/ssl/certs/ca-certificates.crt\"",
    "/usr/bin/waterfox about:blank",
    "/usr/bin/foot",
    "/usr/bin/waterfox-session-clipboard-proof",
    "/usr/bin/mdevd",
    "mdevd\", \"-O\", \"4\", \"-f\", \"/etc/mdev.conf\", \"-C",
    "SEATD_VTBOUND: \"0\"",
    "/usr/bin/su \"laputa\" \"--\" \"/usr/bin/waterfox-dwl-session\" \"--user\"",
  ] {
    ensure(term in script, "waterfox-session", f"session script missing ${term}")?
  }

  for term in [
    "DBus",
    "dbus",
    "PipeWire",
    "pipewire",
    "PulseAudio",
    "pulseaudio",
    "portal",
    "Xwayland",
    "xwayland",
  ] {
    ensure(! (term in script), "waterfox-session", f"session script starts forbidden service term ${term}")?
  }
}

proc verify_boot_hook(root: FsRoot) [fs, error] {
  verify_executable(root, p"usr/lib/init/rc.d/waterfox-dwl-session.boot", "waterfox-hook")?
  let body = fs.root_read_text(root, p"usr/lib/init/rc.d/waterfox-dwl-session.boot")?
  ensure("detach: true" in body, "waterfox-hook", "boot hook does not detach the browser session")?
  ensure("new_session: true" in body, "waterfox-hook", "boot hook does not start a new session")?
}

proc verify_minimal_alsa_tools(rootfs: Path) [fs, process, error] {
  let allowed = set.from(["alsactl", "amixer", "aplay"])
  let bin = fp"${rootfs}/usr/bin"

  for entry in fs.ls(bin)? {
    if entry.name.starts_with("alsa") or entry.name == "amixer" or entry.name == "aplay" or entry.name == "arecord" {
      ensure(set.has(allowed, entry.name), "waterfox-alsa-tools", f"unexpected ALSA tool installed: ${entry.name}")?
    }
  }

  verify_needed(fp"${rootfs}/usr/lib/libasound.so.2", ["libc.so"])?
  verify_chroot_command(rootfs, ["/usr/bin/aplay", "--version"], "waterfox-aplay-version", "aplay: version 1.2.15.2")?
  verify_chroot_command(rootfs, ["/usr/bin/amixer", "--version"], "waterfox-amixer-version", "amixer version 1.2.15.2")?
  verify_chroot_command(rootfs, ["/usr/bin/alsactl", "-v"], "waterfox-alsactl-version", "alsactl version 1.2.15.2")?
}

proc verify_wlroots_mesa(rootfs: Path, root: FsRoot) [fs, process, error] {
  verify_file(root, p"usr/lib/pkgconfig/wlroots-0.19.pc", "waterfox-wlroots-pkgconfig")?
  let body = fs.root_read_text(root, p"usr/lib/pkgconfig/wlroots-0.19.pc")?

  for required in [
    "have_drm_backend=true",
    "have_libinput_backend=true",
    "have_session=true",
    "have_gles2_renderer=true",
    "have_gbm_allocator=true",
  ] {
    ensure(required in body, "waterfox-wlroots-features", f"missing ${required}")
  }

  for disabled in ["have_x11_backend=false", "have_xwayland=false", "have_vulkan_renderer=false"] {
    ensure(disabled in body, "waterfox-wlroots-features", f"missing ${disabled}")
  }

  verify_needed(fp"${rootfs}/usr/lib/libEGL.so.1", ["libgallium-24.2.8.so", "libgbm.so.1"])?
  verify_needed(fp"${rootfs}/usr/lib/libgbm.so.1", ["libgallium-24.2.8.so"])?
  verify_needed(fp"${rootfs}/usr/lib/libwlroots-0.19.so", ["libEGL.so.1", "libGLESv2.so.2", "libgbm.so.1"])?
}

proc verify_chroot_command(rootfs: Path, argv: List[Str], kind: Str, expected: Str) [process, error] {
  let chroot = process.which("chroot")?
  let out = run.text --timeout=30s $chroot $rootfs @argv ?
  ensure(expected in out, kind, f"unexpected output: ${out.trim()}")?
}

proc verify_pm_info(rootfs: Path, xsh_bin: Path, pm_script: Path) [fs, process, error] {
  let work_root = fs.tempdir()?
  defer fs.close_root(work_root)?
  let work = fs.root_path(work_root)?
  let out_root = fs.tempdir()?
  defer fs.close_root(out_root)?
  let out = fs.root_path(out_root)?
  let info = run.text $xsh_bin $pm_script -- info $rootfs $work $out waterfox-dwl-session ?
  ensure("waterfox-dwl-session 1-16" in info, "waterfox-pm-info", "pm info does not report waterfox-dwl-session 1-16")

  for dep in ["waterfox-bin", "dwl-minimal", "seatd", "mdevd", "libudev-zero", "ca-certificates", "foot-minimal"] {
    ensure(dep in info, "waterfox-pm-info", f"pm info missing dependency ${dep}")?
  }

  for term in [
    "DBus",
    "dbus",
    "PipeWire",
    "pipewire",
    "PulseAudio",
    "pulseaudio",
    "Xwayland",
    "xwayland",
  ] {
    ensure(! (term in info), "waterfox-pm-info", f"pm info includes forbidden dependency term ${term}")?
  }
}

proc verify_private_needed(rootfs: Path, allowed_external_sonames: Path, private_needed_script: Path) [fs, error] {
  let private_needed = module.load(private_needed_script)?.require(PrivateNeededModule)?
  let waterfox_root = fp"${rootfs}/opt/waterfox"
  let _ = private_needed.verify_private_needed(waterfox_root, allowed_external_sonames, waterfox_root)?
}

proc main(
  rootfs: Path = /rootfs,
  xsh_bin: Path = /bin/xsh,
  pm_script: Path = /usr/lib/pm/pm.xsh,
  allowed_external_sonames: Path = p"packages/repo/waterfox-bin/files/waterfox-allowed-external.sonames",
  private_needed_script: Path = p"packages/repo/waterfox-bin/files/waterfox-private-needed.xsh",
) [fs, process, error] {
  let root = fs.open_root(rootfs)?
  defer fs.close_root(root)
  verify_packages(rootfs, root)?
  verify_ca_certificates(root)?
  verify_groups(root)?
  verify_session_script(root)?
  verify_boot_hook(root)?
  verify_executable(root, p"usr/bin/waterfox", "waterfox-wrapper")?
  verify_executable(root, p"opt/waterfox/waterfox-bin", "waterfox-bin")?
  verify_executable(root, p"usr/bin/waterfox-dwl-session", "waterfox-session")?
  verify_executable(root, p"usr/bin/waterfox-session-clipboard-proof", "waterfox-clipboard-proof")?
  verify_executable(root, p"usr/bin/su", "waterfox-su")?
  verify_executable(root, p"usr/bin/dwl", "waterfox-dwl")?
  verify_executable(root, p"usr/bin/foot", "waterfox-foot")?
  verify_executable(root, p"usr/bin/mdevd", "waterfox-mdevd")?
  verify_executable(root, p"usr/bin/mdevd-coldplug", "waterfox-mdevd-coldplug")?
  verify_executable(root, p"usr/bin/seatd", "waterfox-seatd")?
  verify_executable(root, p"usr/bin/wl-copy", "waterfox-wl-copy")?
  verify_executable(root, p"usr/bin/wl-paste", "waterfox-wl-paste")?
  verify_executable(root, p"usr/bin/aplay", "waterfox-aplay")?
  verify_executable(root, p"usr/bin/amixer", "waterfox-amixer")?
  verify_executable(root, p"usr/bin/alsactl", "waterfox-alsactl")?
  verify_file(root, p"usr/lib/libudev.so.1", "waterfox-libudev-zero")?
  verify_file(root, p"etc/mdev.conf", "waterfox-mdev-conf")?
  verify_file(root, p"etc/asound.conf", "waterfox-asound-conf")?
  verify_file(root, p"usr/share/alsa/alsa.conf", "waterfox-alsa-conf")?
  verify_file(root, p"usr/share/alsa/ucm2/ucm.conf", "waterfox-ucm")?
  verify_file(root, p"usr/lib/libEGL.so.1", "waterfox-egl")?
  verify_file(root, p"usr/lib/libGLESv2.so.2", "waterfox-gles")?
  verify_file(root, p"usr/lib/libgbm.so.1", "waterfox-gbm")?
  verify_file(root, p"usr/lib/libva.so.2", "waterfox-vaapi")?
  verify_file(root, p"usr/lib/libva-drm.so.2", "waterfox-vaapi-drm")?
  verify_file(root, p"usr/lib/libva-wayland.so.2", "waterfox-vaapi-wayland")?
  verify_file(root, p"usr/lib/dri/virtio_gpu_drv_video.so", "waterfox-virtio-vaapi")?
  verify_waterfox_metadata(root)?
  verify_chroot_command(rootfs, ["/usr/bin/wl-copy", "--version"], "waterfox-wl-copy-version", "wl-clipboard 2.3.0")?
  verify_chroot_command(rootfs, ["/usr/bin/wl-paste", "--version"], "waterfox-wl-paste-version", "wl-clipboard 2.3.0")?
  verify_minimal_alsa_tools(rootfs)?
  verify_wlroots_mesa(rootfs, root)?
  verify_pm_info(rootfs, xsh_bin, pm_script)?
  verify_private_needed(rootfs, allowed_external_sonames, private_needed_script)?
  print "waterfox proof ok"
}

main(@args)?
