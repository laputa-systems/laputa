##! Behavior coverage for loading and validating the qemu-dwl-foot profile.
use laputa.profile as profile
use laputa.types as types

pure profiles_root() -> Path {
  p"profiles"
}

proc test_qemu_dwl_foot_profile_has_exact_runtime_intent() [fs, error] {
  let value = profile.load("qemu-dwl-foot", profiles_root())?
  test.eq(types.system_target_text(value.target), "aarch64-linux-musl")?
  test.eq(
    value.package_roots,
    ["baselayout", "xsh", "laputa-pm", "xinit", "mdevd", "seatd", "dwl-minimal", "foot-minimal"],
  )?
  test.eq(value.kernel_package, "linux")?
  test.ok(! (value.kernel_package in value.package_roots))?
  test.eq(value.kernel_path, p"boot/vmlinuz")?
  test.eq(value.session.interactive_argv, ["/usr/bin/dwl", "-s", "/usr/bin/foot /bin/xshi --no-config"])?
  test.eq(value.session.proof_argv, ["/usr/bin/dwl", "-s", "/usr/bin/foot /bin/xsh /run/qemu-dwl-foot-proof.xsh"])?
  test.eq(value.qemu, {machine: "virt,accel=hvf,highmem=off", cpu: "host", smp: 2, memory: "1536M", width: 1280, height: 800})?
  test.eq(value.forbidden_packages, ["llvm-toolchain", "pkgconf", "cmake", "muon", "samurai", "m4", "flex", "bison", "wayland-dev", "wayland-protocols", "pixman-dev", "dbus", "systemd", "xwayland", "gtk", "pango", "pipewire", "pulseaudio", "python"])?
  test.eq(value.forbidden_sonames, ["libLLVM", "libclang", "libpython", "libgtk", "libpango", "libpipewire", "libpulse"])?
}

proc test_profile_load_rejects_unknown_and_path_names() [fs, error] {
  match profile.load("missing", profiles_root()) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  match profile.load("../qemu-dwl-foot", profiles_root()) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  match profile.load("qemu-dwl-foot.xsh", profiles_root()) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
}

proc test_profile_validation_rejects_duplicate_or_invalid_roots() [error] {
  let valid: types.SystemProfile = {
    name: "valid",
    target: types.Aarch64LinuxMusl,
    package_roots: ["one"],
    kernel_package: "linux",
    kernel_path: p"boot/vmlinuz",
    session: {compositor: p"/usr/bin/dwl", terminal: p"/usr/bin/foot", interactive_argv: ["dwl"], proof_argv: ["dwl"]},
    qemu: {machine: "virt", cpu: "host", smp: 1, memory: "512M", width: 1, height: 1},
    proof: {success_markers: ["ok"], failure_markers: ["failed"], input_text: "x", screenshot_required: true},
    forbidden_packages: [],
    forbidden_sonames: [],
  }
  profile.validate(valid)?
  match profile.validate({...valid, package_roots: ["one", "one"]}) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  match profile.validate({...valid, package_roots: ["/one"]}) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  match profile.validate({...valid, package_roots: ["linux"]}) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  match profile.validate({...valid, forbidden_packages: ["/llvm-toolchain"]}) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
  match profile.validate({...valid, forbidden_sonames: ["libLLVM", "libLLVM"]}) {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
}

proc test_profile_digest_is_deterministic() [fs, error] {
  let value = profile.load("qemu-dwl-foot", profiles_root())?
  test.eq(profile.digest(value)?, profile.digest(value)?)?
  test.ok(profile.digest(value)? != profile.digest({...value, qemu: {...value.qemu, smp: 3}})?)?
}
