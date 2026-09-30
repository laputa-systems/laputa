##! Behavior coverage for loading and validating the qemu-dwl-foot profile.
use laputa.profile as profile
use laputa.types as types

pure profiles_root() -> Path {
  p"profiles"
}

test test_qemu_dwl_foot_profile_has_exact_runtime_intent [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", profiles_root())?
  value.package_roots == [
    "baselayout",
    "xsh",
    "laputa-pm",
    "xinit",
    "mdevd",
    "seatd",
    "dwl-minimal",
    "foot-minimal",
  ]
  value.kernel_package == "linux"
  ! (value.kernel_package in value.package_roots)
  value.kernel_path == p"boot/vmlinuz"
  value.qemu_machine == "virt,accel=hvf,highmem=off"
  value.qemu_cpu == "host"
  value.qemu_smp == 2
  value.qemu_memory == "1536M"
  value.qemu_width == 1280
  value.qemu_height == 800
  value.forbidden_packages == [
    "llvm-toolchain",
    "pkgconf",
    "cmake",
    "muon",
    "samurai",
    "m4",
    "flex",
    "bison",
    "wayland-dev",
    "wayland-protocols",
    "pixman-dev",
    "dbus",
    "systemd",
    "xwayland",
    "gtk",
    "pango",
    "pipewire",
    "pulseaudio",
    "python",
  ]
  value.forbidden_sonames == ["libLLVM", "libclang", "libpython", "libgtk", "libpango", "libpipewire", "libpulse"]
}

test test_profile_load_rejects_unknown_and_path_names [fs, error] {
  match profile.load_system_profile("missing", profiles_root()) {
    Ok(_) => false
    Err(_) => {}
  }

  match profile.load_system_profile("../qemu-dwl-foot", profiles_root()) {
    Ok(_) => false
    Err(_) => {}
  }

  match profile.load_system_profile("qemu-dwl-foot.xsh", profiles_root()) {
    Ok(_) => false
    Err(_) => {}
  }
}

test test_profile_validation_rejects_duplicate_or_invalid_roots [error] {
  let valid: types.SystemProfile = types.SystemProfile(
    name: "valid",
    package_roots: ["one"],
    kernel_package: "linux",
    kernel_path: p"boot/vmlinuz",
    qemu_machine: "virt",
    qemu_cpu: "host",
    qemu_smp: 1,
    qemu_memory: "512M",
    qemu_width: 1,
    qemu_height: 1,
    forbidden_packages: [],
    forbidden_sonames: [],
  )
  profile.validate_system_profile(valid)?
  match profile.validate_system_profile({...valid, package_roots: ["one", "one"]}) {
    Ok(_) => false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, package_roots: ["/one"]}) {
    Ok(_) => false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, package_roots: ["linux"]}) {
    Ok(_) => false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, forbidden_packages: ["/llvm-toolchain"]}) {
    Ok(_) => false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, forbidden_sonames: ["libLLVM", "libLLVM"]}) {
    Ok(_) => false
    Err(_) => {}
  }
}

test test_profile_digest_is_deterministic [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", profiles_root())?
  profile.digest(value)? == profile.digest(value)?
  profile.digest(value)? != profile.digest({...value, qemu_smp: 3})?
}
