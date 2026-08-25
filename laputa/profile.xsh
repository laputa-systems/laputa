##! Loading, validation, and deterministic identity for typed Laputa profiles.
use laputa.types as types

type SystemProfileModule = module {
  export let profile: types.SystemProfile
}

## Return whether `value` is a simple profile file stem rather than a path.
export proc valid_profile_name(value: Str) [error] -> Result[Bool] {
  if value == "" or "/" in value or "\\" in value or value == "." or value == ".." {
    return false
  }

  let name_re = regex.compile("^[a-z0-9][a-z0-9-]*$")?
  name_re.matches(value)
}

## Return whether `value` can name a package at a typed profile boundary.
export proc valid_package_name(value: Str) [error] -> Result[Bool] {
  let package_re = regex.compile("^[a-z0-9][a-z0-9+._-]*$")?
  package_re.matches(value)
}

## Validate a complete profile before it is used to construct any build command.
export proc validate(value: types.SystemProfile) [error] -> Result[Unit] {
  if ! valid_profile_name(value.name)? {
    return Err(types.LaputaError.Profile(f"invalid profile name ${value.name}"))
  }

  match value.target {
    Aarch64LinuxMusl => {}
    UnsupportedSystemTarget => return Err(types.LaputaError.Profile(f"${value.name} has an unsupported target"))
  }

  if value.package_roots.len() == 0 {
    return Err(types.LaputaError.Profile(f"${value.name} has no runtime package roots"))
  }

  var roots: Map[Bool] = {}

  for package_name in value.package_roots {
    if ! valid_package_name(package_name)? {
      return Err(types.LaputaError.Profile(f"${value.name} has invalid package root ${package_name}"))
    }

    if roots.get(package_name, false) {
      return Err(types.LaputaError.Profile(f"${value.name} names ${package_name} more than once"))
    }

    roots[package_name] = true
  }

  if ! valid_package_name(value.kernel_package)? {
    return Err(types.LaputaError.Profile(f"${value.name} has invalid kernel package ${value.kernel_package}"))
  }

  if roots.get(value.kernel_package, false) {
    return Err(types.LaputaError.Profile(f"${value.name} must select ${value.kernel_package} only as its kernel package"))
  }

  if value.kernel_path.display() == "" or value.kernel_path.display().starts_with("/") {
    return Err(types.LaputaError.Profile(f"${value.name} has an invalid kernel manifest path"))
  }

  if value.session.compositor.display() == "" or ! value.session.compositor.display().starts_with("/") {
    return Err(types.LaputaError.Profile(f"${value.name} has an invalid compositor path"))
  }

  if value.session.terminal.display() == "" or ! value.session.terminal.display().starts_with("/") {
    return Err(types.LaputaError.Profile(f"${value.name} has an invalid terminal path"))
  }

  if value.session.interactive_argv.len() == 0 or value.session.proof_argv.len() == 0 {
    return Err(types.LaputaError.Profile(f"${value.name} must declare interactive and proof session arguments"))
  }

  if value.qemu.machine == "" or value.qemu.cpu == "" or value.qemu.smp <= 0 or value.qemu.memory == "" or value.qemu.width <= 0 or value.qemu.height <= 0 {
    return Err(types.LaputaError.Profile(f"${value.name} has an invalid QEMU specification"))
  }

  if value.proof.success_markers.len() == 0 or value.proof.failure_markers.len() == 0 or value.proof.input_text == "" {
    return Err(types.LaputaError.Profile(f"${value.name} has an incomplete guest proof contract"))
  }

  var forbidden_packages: Map[Bool] = {}
  for package_name in value.forbidden_packages {
    if ! valid_package_name(package_name)? {
      return Err(types.LaputaError.Profile(f"${value.name} has invalid forbidden package ${package_name}"))
    }

    if forbidden_packages.get(package_name, false) {
      return Err(types.LaputaError.Profile(f"${value.name} names forbidden package ${package_name} more than once"))
    }

    forbidden_packages[package_name] = true
  }

  var forbidden_sonames: Map[Bool] = {}
  for soname in value.forbidden_sonames {
    if soname == "" or soname.contains("/") or soname.contains("\\") {
      return Err(types.LaputaError.Profile(f"${value.name} has invalid forbidden SONAME ${soname}"))
    }

    if forbidden_sonames.get(soname, false) {
      return Err(types.LaputaError.Profile(f"${value.name} names forbidden SONAME ${soname} more than once"))
    }

    forbidden_sonames[soname] = true
  }
}

## Load one named profile from `profiles_root` and validate its typed export.
export proc load(name: Str, profiles_root: Path) [fs, error] -> Result[types.SystemProfile] {
  if ! valid_profile_name(name)? {
    return Err(types.LaputaError.Profile(f"invalid profile name ${name}"))
  }

  let source = fp"${profiles_root}/${name}.xsh"

  if ! fs.exists(source)? {
    return Err(types.LaputaError.Profile(f"unknown profile ${name}"))
  }

  let exports = module.load(source)?.require(SystemProfileModule)?
  let value = exports.profile
  validate(value)?
  value
}

## Compute a canonical digest from all semantic profile fields.
export proc digest(value: types.SystemProfile) [error] -> Result[Str] {
  validate(value)?
  let body = f"""laputa-system-profile-1
name\t${value.name}
target\t${types.system_target_text(value.target)}
roots\t${value.package_roots.join(",")}
kernel-package\t${value.kernel_package}
kernel-path\t${value.kernel_path.display()}
compositor\t${value.session.compositor.display()}
terminal\t${value.session.terminal.display()}
interactive\t${value.session.interactive_argv.join("\u{1f}")}
proof\t${value.session.proof_argv.join("\u{1f}")}
machine\t${value.qemu.machine}
cpu\t${value.qemu.cpu}
smp\t${value.qemu.smp}
memory\t${value.qemu.memory}
width\t${value.qemu.width}
height\t${value.qemu.height}
success\t${value.proof.success_markers.join("\u{1f}")}
failure\t${value.proof.failure_markers.join("\u{1f}")}
input\t${value.proof.input_text}
screenshot\t${value.proof.screenshot_required}
forbidden-packages\t${value.forbidden_packages.join(",")}
forbidden-sonames\t${value.forbidden_sonames.join(",")}
"""
  bytes.from_text(body).sha256().hex()
}
