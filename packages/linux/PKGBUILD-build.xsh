##! Linux package build implementation, intentionally outside the dynamically loaded recipe metadata boundary.
use PKGBUILD-aarch64 as PKGBUILD_aarch64
use PKGBUILD-shared as PKGBUILD_shared
use PKGBUILD-x86_64 as PKGBUILD_x86_64
use kbuild
use linux_config
use parser_gen
use pm.util as pm_util

proc package_arch() -> Result[Str] {
  let arch = pm_util.target_arch()?

  return arch when arch == "aarch64" or arch == "x86_64"

  Err(kbuild.ScriptError.Failed(kind: "linux-unsupported-arch", message: f"unsupported linux package arch {arch}"))
}

pure linux_srcarch(package_arch_value: Str) -> Result[Str] {
  return "arm64" when package_arch_value == "aarch64"

  return "x86" when package_arch_value == "x86_64"

  Err(
    kbuild.ScriptError.Failed(kind: "linux-unsupported-arch", message: f"unsupported linux package arch {package_arch_value}"),
  )
}

pure kernel_config_fragments_for(package_arch_value: Str) -> Result[List[Path]] {
  if package_arch_value == "aarch64" {
    return [p"files/config/aarch64/base-aarch64.fragment"]
  }

  return [p"files/config/x86_64/base-x86_64.fragment"] when package_arch_value == "x86_64"

  Err(
    kbuild.ScriptError.Failed(kind: "linux-unsupported-arch", message: f"unsupported linux package arch {package_arch_value}"),
  )
}

pure kernel_image_for(package_arch_value: Str) -> Result[Path] {
  return p"arch/arm64/boot/Image" when package_arch_value == "aarch64"

  return p"arch/x86/boot/bzImage" when package_arch_value == "x86_64"

  Err(
    kbuild.ScriptError.Failed(kind: "linux-unsupported-arch", message: f"unsupported linux package arch {package_arch_value}"),
  )
}

proc build_native_scratch(cc: Path, srcarch: Str, version: Str) {
  if srcarch == "arm64" {
    PKGBUILD_aarch64.build_scratch(cc, srcarch, version)
    return
  }

  if srcarch == "x86" {
    PKGBUILD_x86_64.build_x86_64_scratch(cc, srcarch, version)
    return
  }

  return Err(
    kbuild.ScriptError.Failed(
      kind: "linux-native-kbuild-unsupported-arch",
      message: f"native scratch Kbuild final link is only implemented for arm64 and x86; {srcarch} needs new arch support",
    ),
  )
}

proc build_cc() -> Result[Path] {
  let root = e"XSH_PM_BUILD_ROOT" ?? ""

  if root != "" {
    let cc = fp"{root}/usr/bin/cc"

    if ! cc.exists()? {
      return Err(kbuild.ScriptError.Failed(kind: "linux-build-cc", message: f"missing build-root compiler: {cc}"))?
    }

    return cc
  }

  process.which("cc")?
}

proc main(dest: Path) [fs, process, env, time, error] {
  let version = e"XSH_PM_VERSION" ?? ""
  let package_start = PKGBUILD_shared.timing_start("package-total")
  let cc = build_cc()?
  let arch = package_arch()?
  let srcarch = linux_srcarch(arch)?
  let config_start = PKGBUILD_shared.timing_start("config")
  let config_fragments = linux_config.resolve_config_fragments(kernel_config_fragments_for(arch)?)?
  linux_config.write_resolved_config(p".", srcarch, config_fragments, p".config")
  PKGBUILD_shared.timing_done("config", config_start)
  let parser_start = PKGBUILD_shared.timing_start("parser")
  parser_gen.generate_linux_parsers()
  PKGBUILD_shared.timing_done("parser", parser_start)
  let kbuild_start = PKGBUILD_shared.timing_start("kbuild")
  build_native_scratch(cc, srcarch, version)
  PKGBUILD_shared.timing_done("kbuild", kbuild_start)
  let install_start = PKGBUILD_shared.timing_start("install")
  let image = kernel_image_for(arch)?
  fs.install(image, fp"{dest}/boot/vmlinuz-{version}", 0o644, parents: true, overwrite: true)
  fs.install(image, fp"{dest}/boot/vmlinuz", 0o644, parents: true, overwrite: true)
  fs.install(p".config", fp"{dest}/usr/share/linux/config-{version}", 0o644, parents: true, overwrite: true)
  PKGBUILD_shared.timing_done("install", install_start)
  PKGBUILD_shared.timing_done("package-total", package_start)
}

main(@args)
