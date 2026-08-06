error ProofError = Failed(kind: Str, message: Str)

pure required_packages() -> List[Str] {
  [
    "baselayout",
    "dwl-minimal",
    "expat",
    "fcft-minimal",
    "font-ttf-hack",
    "fontconfig",
    "freetype",
    "hwdata",
    "libdisplay-info",
    "libdrm",
    "libevdev",
    "libffi",
    "libinput",
    "libpng",
    "libseat",
    "libudev-zero",
    "libxkbcommon",
    "mdevd",
    "mtdev",
    "pixman",
    "seatd",
    "tllist",
    "wayland-libs-client",
    "wayland-libs-cursor",
    "wayland-libs-server",
    "wayland-protocols",
    "wlroots0.19-mesa",
    "xkeyboard-config",
  ]
}

pure forbidden_package_terms() -> List[Str] {
  [
    "dbus",
    "DBus",
    "gtk",
    "GTK",
    "harfbuzz",
    "HarfBuzz",
    "libva",
    "ncurses",
    "pango",
    "Pango",
    "pipewire",
    "PipeWire",
    "portal",
    "PulseAudio",
    "pulseaudio",
    "python",
    "Python",
    "systemd",
    "terminfo",
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
  [
    "libasound",
    "libcairo",
    "libdbus",
    "libEGL",
    "libfribidi",
    "libgbm",
    "libgdk",
    "libgio",
    "libglib",
    "libGLX",
    "libgobject",
    "libgtk",
    "libharfbuzz",
    "libncurses",
    "libpango",
    "libpipewire",
    "libpulse",
    "libpython",
    "libterminfo",
    "libva",
    "libvulkan",
    "libX11",
    "libxcb",
  ]
}

proc ensure(condition: Bool, kind: Str, message: Str) [error] {
  if ! condition {
    return Err(ProofError.Failed(kind, message))
  }
}

proc verify_package_present(root: FsRoot, name: Str) [fs, error] {
  ensure(
    fs.root_exists(root, fp"var/lib/xsh-pm/packages/${name}")?,
    "dwl-foot-package",
    f"missing installed package ${name}",
  )?
}

proc verify_packages(rootfs: Path, root: FsRoot) [fs, error] {
  let db = fp"${rootfs}/var/lib/xsh-pm/packages"
  ensure(fs.root_exists(root, p"var/lib/xsh-pm/packages")?, "dwl-foot-package-db", "missing package database")?

  for name in required_packages() {
    verify_package_present(root, name)?
  }

  for entry in fs.ls(db)? |> where .kind == "dir" {
    for term in forbidden_package_terms() {
      ensure(! (term in entry.name), "dwl-foot-package", f"forbidden package installed: ${entry.name}")
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
        ensure(! (term in line), "dwl-foot-needed", f"${path_value.display()} needs forbidden ${line.trim()}")
      }

      let left = line.split("[")
      ensure(left.len() > 1, "dwl-foot-needed", f"could not parse ${line.trim()}")?
      let right = left[1].split("]")
      ensure(right.len() > 0, "dwl-foot-needed", f"could not parse ${line.trim()}")?
      entries = entries.push(right[0])
    }
  }

  entries
}

proc verify_needed(path_value: Path, required: List[Str]) [fs, process, error] {
  let entries = needed_entries(path_value)?

  for soname in required {
    ensure(soname in entries, "dwl-foot-needed", f"${path_value.display()} missing ${soname}")
  }
}

proc verify_wlroots_features(root: FsRoot) [fs, error] {
  verify_file(root, p"usr/lib/pkgconfig/wlroots-0.19.pc", "dwl-foot-wlroots-pkgconfig")?
  let body = fs.root_read_text(root, p"usr/lib/pkgconfig/wlroots-0.19.pc")?

  for required in ["have_drm_backend=true", "have_libinput_backend=true", "have_session=true"] {
    ensure(required in body, "dwl-foot-wlroots-features", f"missing ${required}")
  }

  for disabled in [
    "have_x11_backend=false",
    "have_xwayland=false",
    "have_gles2_renderer=false",
    "have_vulkan_renderer=false",
    "have_gbm_allocator=false",
    "have_udmabuf_allocator=false",
  ] {
    ensure(disabled in body, "dwl-foot-wlroots-features", f"missing ${disabled}")
  }
}

proc verify_no_binary_reference(path_value: Path, term: Str, kind: Str) [process, error] {
  let grep = process.which("grep")?
  let status = run.status $grep "-a" "-q" $term $path_value
  ensure(status.exited(), kind, f"grep did not exit while checking ${term}")?
  ensure(status.exit_code()? == 1, kind, f"${path_value.display()} contains forbidden reference ${term}")
}

proc verify_chroot_command(rootfs: Path, argv: List[Str], kind: Str, expected: Str) [process, error] {
  let chroot = process.which("chroot")?
  let out = run.text $chroot $rootfs @argv ?
  ensure(expected in out, kind, f"unexpected output: ${out.trim()}")?
}

proc verify_fontconfig(rootfs: Path) [process, error] {
  verify_chroot_command(rootfs, ["/usr/bin/fc-match", "Hack"], "dwl-foot-fc-match", "Hack")
}

proc verify_pm_info(rootfs: Path, xsh_bin: Path, pm_script: Path) [fs, process, error] {
  let work_root = fs.tempdir()?
  defer fs.close_root(work_root)?
  let work = fs.root_path(work_root)?
  let out_root = fs.tempdir()?
  defer fs.close_root(out_root)?
  let out = fs.root_path(out_root)?
  let info = run.text $xsh_bin $pm_script -- info $rootfs $work $out foot-minimal ?
  ensure("foot-minimal 1.27.0-1" in info, "dwl-foot-pm-info", "pm info does not report foot-minimal 1.27.0-1")

  for term in forbidden_package_terms() {
    ensure(! (term in info), "dwl-foot-pm-info", f"pm info includes forbidden dependency term ${term}")
  }
}

proc main(rootfs: Path = /rootfs, xsh_bin: Path = /bin/xsh, pm_script: Path = /usr/lib/pm/pm.xsh) [fs, process, error] {
  let root = fs.open_root(rootfs)?
  defer fs.close_root(root)
  verify_packages(rootfs, root)?
  verify_file(root, p"usr/lib/libwayland-server.so.0", "dwl-foot-wayland-server")?
  verify_file(root, p"usr/lib/libwayland-client.so.0", "dwl-foot-wayland-client")?
  verify_file(root, p"usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml", "dwl-foot-wayland-protocols")?
  verify_file(root, p"usr/share/X11/xkb/rules/evdev", "dwl-foot-xkeyboard-config")?
  verify_file(root, p"usr/lib/libudev.so.1", "dwl-foot-libudev-zero")?
  verify_file(root, p"etc/mdev.conf", "dwl-foot-mdev-conf")?
  verify_file(root, p"usr/lib/libdrm.so.2", "dwl-foot-libdrm")?
  verify_file(root, p"usr/lib/libdisplay-info.so", "dwl-foot-libdisplay-info")?
  verify_file(root, p"usr/lib/libevdev.so.2", "dwl-foot-libevdev")?
  verify_file(root, p"usr/lib/libmtdev.so.1", "dwl-foot-mtdev")?
  verify_file(root, p"usr/lib/libinput.so.10", "dwl-foot-libinput")?
  verify_file(root, p"usr/lib/libseat.so.1", "dwl-foot-libseat")?
  verify_file(root, p"usr/lib/libpixman-1.so.0", "dwl-foot-pixman")?
  verify_file(root, p"usr/lib/libwlroots-0.19.so", "dwl-foot-wlroots")?
  verify_executable(root, p"usr/bin/mdevd", "dwl-foot-mdevd")?
  verify_executable(root, p"usr/bin/mdevd-coldplug", "dwl-foot-mdevd-coldplug")?
  verify_executable(root, p"usr/bin/seatd", "dwl-foot-seatd")?
  verify_executable(root, p"usr/bin/dwl", "dwl-foot-dwl")?
  verify_executable(root, p"usr/bin/foot", "dwl-foot-foot")?
  verify_executable(root, p"usr/bin/fc-match", "dwl-foot-fc-match-bin")?
  verify_executable(root, p"usr/bin/fc-cache", "dwl-foot-fc-cache-bin")?
  verify_file(root, p"usr/share/fonts/TTF/Hack-Regular.ttf", "dwl-foot-hack-font")?
  verify_file(root, p"etc/xdg/foot/foot.ini", "dwl-foot-foot-config")?
  verify_wlroots_features(root)?

  verify_needed(
    fp"${rootfs}/usr/bin/dwl",
    ["libwlroots-0.19.so", "libwayland-server.so.0", "libxkbcommon.so.0", "libinput.so.10"],
  )?

  verify_needed(
    fp"${rootfs}/usr/bin/foot",
    ["libwayland-client.so.0", "libwayland-cursor.so.0", "libxkbcommon.so.0", "libfcft.so.4"],
  )?

  verify_needed(fp"${rootfs}/usr/lib/libwlroots-0.19.so", ["libpixman-1.so.0", "libinput.so.10"])?
  verify_no_binary_reference(fp"${rootfs}/usr/bin/dwl", "/bin/sh", "dwl-foot-dwl-shell")?
  verify_no_binary_reference(fp"${rootfs}/usr/bin/dwl", "wmenu-run", "dwl-foot-dwl-launcher")?
  verify_chroot_command(rootfs, ["/usr/bin/dwl", "-v"], "dwl-foot-dwl-version", "dwl 0.8")?
  verify_chroot_command(rootfs, ["/usr/bin/foot", "--version"], "dwl-foot-foot-version", "foot version: 1.27.0")?
  verify_fontconfig(rootfs)?
  verify_pm_info(rootfs, xsh_bin, pm_script)?
  print "dwl foot minimal ok"
}

main(@args)?
