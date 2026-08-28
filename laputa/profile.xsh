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

  if value.qemu_machine == "" or value.qemu_cpu == "" or value.qemu_smp <= 0 or value.qemu_memory == "" or value.qemu_width <= 0 or value.qemu_height <= 0 {
    return Err(types.LaputaError.Profile(f"${value.name} has an invalid QEMU specification"))
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
roots\t${value.package_roots.join(",")}
kernel-package\t${value.kernel_package}
kernel-path\t${value.kernel_path.display()}
machine\t${value.qemu_machine}
cpu\t${value.qemu_cpu}
smp\t${value.qemu_smp}
memory\t${value.qemu_memory}
width\t${value.qemu_width}
height\t${value.qemu_height}
forbidden-packages\t${value.forbidden_packages.join(",")}
forbidden-sonames\t${value.forbidden_sonames.join(",")}
"""
  bytes.from_text(body).sha256().hex()
}
