use packages.linux.config_drift as drift
use packages.llvm-toolchain.PKGBUILD as llvm_recipe
use packages.upstream_pins as upstream_pins

cli main(source: Path, llvm_bin: Path, output: Path, host_cc: Path) [fs, process, env, error] {
  let source_root = path.absolute(source)?
  let compiler_root = path.absolute(llvm_bin)?
  let output_root = path.absolute(output)?
  let host_compiler = path.absolute(host_cc)?
  let compiler = fp"{compiler_root}/clang"
  let version = run.capture --text $compiler "--version"

  if ! version.status.ok or version.stdout.split("\n")[0] != f"clang version {llvm_recipe.ver}" {
    return Err(error.failure(f"expected pinned clang {llvm_recipe.ver}: {version.stdout}{version.stderr}"))?
  }

  let makefile = fp"{source_root}/Makefile".read_text()?
  var kernel_version: Map[Str] = {}

  for line in makefile.split("\n") {
    let parts = line.split(" = ")

    if parts.len() == 2 and parts[0] in ["VERSION", "PATCHLEVEL", "SUBLEVEL", "EXTRAVERSION"] {
      kernel_version[parts[0]] = parts[1].trim()
    }
  }

  let release = f"{kernel_version.get("VERSION") ?? ""}.{kernel_version.get("PATCHLEVEL") ?? ""}.{kernel_version.get("SUBLEVEL") ?? ""}{kernel_version.get("EXTRAVERSION") ?? ""}"

  if release != upstream_pins.linux_kernel_version {
    return Err(error.failure(f"expected pinned Linux {upstream_pins.linux_kernel_version}, got {release}"))?
  }

  let recipe_root = path.absolute(p"packages/linux")?
  var changed = false

  for arch in ["x86_64", "aarch64"] {
    let srcarch = if arch == "aarch64" { "arm64" } else { "x86_64" }
    let fragment = fp"{recipe_root}/files/config/{arch}/base-{arch}.fragment"
    let build = fp"{output_root}/{arch}"

    if build.exists() {
      return Err(error.failure(f"configuration output must be fresh: {build}"))?
    }

    build.mkdir(parents: true)
    let original = fragment.read_text()?
    fp"{build}/.config".write(original)
    let unavailable = fp"{build}/unavailable-tool"
    run "make" "-C" $source_root f"O={build}" f"ARCH={srcarch}" f"LLVM={compiler_root}/" \
      f"HOSTCC={host_compiler}" f"RUSTC={unavailable}" f"BINDGEN={unavailable}" f"PAHOLE={unavailable}" \
      "olddefconfig"
    let changes = drift.linux_config_changes(original, fp"{build}/.config".read_text()?)

    for change in changes {
      print f"{arch}: {change}"
    }

    print f"{arch}: {changes.len()} changed symbols"
    changed = changed or changes.len() != 0
  }

  if changed {
    return Err(error.failure("kernel configuration drift detected; checked-in fragments were not changed"))?
  }
}
