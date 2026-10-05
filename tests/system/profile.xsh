##! Behavior coverage for loading and validating the qemu-dwl-foot profile.
use system.profile
use system.types

pure profiles_root() -> Path {
  p"profiles"
}

test test_qemu_dwl_foot_profile_has_exact_runtime_intent [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", profiles_root())?
  assert value.package_roots == [
    "baselayout",
    "xsh",
    "laputa-pm",
    "xinit",
    "mdevd",
    "seatd",
    "dwl-minimal",
    "foot-minimal",
  ]
  assert value.kernel_package == "linux"
  assert ! (value.kernel_package in value.package_roots)
  assert value.kernel_path == p"boot/vmlinuz"
  assert value.qemu_smp == 2
  assert value.qemu_memory == "1536M"
  assert value.qemu_width == 1280
  assert value.qemu_height == 800
  assert value.forbidden_packages == [
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
  assert value.forbidden_sonames == [
    "libLLVM",
    "libclang",
    "libpython",
    "libgtk",
    "libpango",
    "libpipewire",
    "libpulse",
  ]
}

test test_profile_load_rejects_unknown_and_path_names [fs, error] {
  match profile.load_system_profile("missing", profiles_root()) {
    Ok(_) => assert false
    Err(_) => {}
  }

  match profile.load_system_profile("../qemu-dwl-foot", profiles_root()) {
    Ok(_) => assert false
    Err(_) => {}
  }

  match profile.load_system_profile("qemu-dwl-foot.xsh", profiles_root()) {
    Ok(_) => assert false
    Err(_) => {}
  }
}

test test_profile_validation_rejects_duplicate_or_invalid_roots [error] {
  let valid: types.SystemProfile = types.SystemProfile(
    name: "valid",
    package_roots: ["one"],
    kernel_package: "linux",
    kernel_path: p"boot/vmlinuz",
    qemu_smp: 1,
    qemu_memory: "512M",
    qemu_width: 1,
    qemu_height: 1,
    forbidden_packages: [],
    forbidden_sonames: [],
  )
  profile.validate_system_profile(valid)
  match profile.validate_system_profile({...valid, package_roots: ["one", "one"]}) {
    Ok(_) => assert false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, package_roots: ["/one"]}) {
    Ok(_) => assert false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, package_roots: ["linux"]}) {
    Ok(_) => assert false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, forbidden_packages: ["/llvm-toolchain"]}) {
    Ok(_) => assert false
    Err(_) => {}
  }

  match profile.validate_system_profile({...valid, forbidden_sonames: ["libLLVM", "libLLVM"]}) {
    Ok(_) => assert false
    Err(_) => {}
  }
}

test test_profile_digest_is_deterministic [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", profiles_root())?
  assert profile.digest(value)? == profile.digest(value)?
  assert profile.digest(value)? != profile.digest({...value, qemu_smp: 3})?
}

test test_profile_rejects_forbidden_packages_in_its_runtime_closure [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", p"profiles")?
  assert profile.forbidden_runtime_packages(value, ["baselayout", "foot-minimal", "musl"]) == []
  assert profile.forbidden_runtime_packages(value, ["baselayout", "llvm-toolchain", "pkgconf"]) == ["llvm-toolchain", "pkgconf"]
}

# Profiles name libraries by their base name; real sonames carry versions.
test test_forbidden_soname_entries_match_versioned_sonames [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", p"profiles")?

  for soname in ["libLLVM.so.23", "libLLVM-23.so", "libLLVM.so", "libclang-cpp.so.23", "libpython3.13.so.1.0"] {
    assert profile.soname_is_forbidden(value, soname), soname
  }

  for soname in ["libc.so", "libEGL.so.1", "libgallium-26.2.4.so", "libLLVMish.so"] {
    assert ! profile.soname_is_forbidden(value, soname), soname
  }
}
