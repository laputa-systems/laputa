##! XSH module `seatd-rs` package and build operations.
use packages.upstream_pins as upstream_pins
use pm.target as pm_target
use pm.rust as pm_rust
use pm.types
use pm.util as pm_util

error SeatdRsBuildError = MissingRustStd(path: Str)

## Package recipe export.
export const name = "seatd-rs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Upstream daemon protocol version.
export const ver = "0.9.3"

## Package recipe export.
export const rel = "3"

## Package recipe export.
## The daemon links libc only.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## The build installs an xinit service module; xinit runs it at runtime.
export const runtime_only_deps = ["xinit"]

## Pinned daemon workspace plus the distribution service module.
export let upstream_sources = upstream_pins.tinyland_workspace_sources.push({
  source: p"service.xsh",
  kind: "auto",
  architectures: ["all"],
  checksums: [{arch: "all", sha256: "SKIP"}],
})

## Installed Rust daemon and supervisor integration.
export const filetree = [
  {path: p"usr/bin/seatd", kind: "binary"},
  {path: p"usr/lib/xinit/services/seatd.xsh", kind: "file"},
]

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cargo = process.which("cargo")?
  let cc = process.which("cc")?
  let target = pm_target.recipe_target()?
  let build_root = fp"{e"XSH_PM_BUILD_ROOT" ?? ""}"
  let target_root_value = (e"LAPUTA_ROOT" ?? e"XSH_PM_ROOT" ?? "").trim()
  let target_root = if target_root_value != "" { fp"{target_root_value}" } else { cc.parent.parent }
  var libdir = fp"{target_root}/usr/lib"

  if ! libdir.exists() {
    libdir = fp"{cc.parent.parent}/lib"
  }

  let build_target = pm_target.build_target()?
  let triple = pm_target.rust_triple(target)?
  let host_triple = pm_target.rust_triple(build_target)?
  let host_cc = if fp"{build_root}/usr/bin/cc".exists() { fp"{build_root}/usr/bin/cc" } else { cc }
  let host_libdir = fp"{build_root}/usr/lib"
  let target_rustlib = fp"rust-std/rust-std-{triple}/lib/rustlib/{triple}"
  let staged_rustlib = fp"{target_root}/usr/lib/rustlib/{triple}"

  if ! fp"{staged_rustlib}/lib".exists() {
    guard target_rustlib.exists() else {
      return Err(SeatdRsBuildError.MissingRustStd(target_rustlib.display()))
    }

    pm_rust.rust_stage_standard_library(target_rustlib, staged_rustlib)
  }

  # panic=abort keeps unwinding (and the libgcc runtime) out of the image.
  # -crt-static selects the dynamic CRT (with an INTERP) like the tinyland
  # harness build: the Laputa musl package ships libc.so but no libc.a, so
  # a fully static Rust link has no static libc to close against.
  let target_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed"
  let host_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={host_cc} -L native={host_libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed"
  let aarch64_rustflags = match target {
    types.Aarch64LinuxMusl => target_rustflags
    types.X86_64LinuxMusl => host_rustflags
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported seatd-rs target")) }
  }

  let x86_64_rustflags = if build_target == types.target_x86_64() and target != build_target {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = match target {
    types.Aarch64LinuxMusl => cc.display()
    types.X86_64LinuxMusl => host_cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported seatd-rs target")) }
  }
  let x86_64_linker = match target {
    types.Aarch64LinuxMusl => host_cc.display()
    types.X86_64LinuxMusl => cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported seatd-rs target")) }
  }

  # The daemon repo carries no container cargo config; the recipe supplies
  # its own link flags below. Tolerate its absence on future pins.
  p".cargo/config.toml".remove()

  let current_path = e"PATH" ?? ""
  let cargo_path = f"{host_cc.parent}:{current_path}"

  env ({
    PATH: cargo_path,
    CC: host_cc.display(),
    HOST_CC: host_cc.display(),
    CARGO_HOME: fp"{fs.cwd()?}/.cargo-home".display(),
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER: aarch64_linker,
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: aarch64_rustflags,
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER: x86_64_linker,
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: x86_64_rustflags,
  }) {
    run $cargo build "--offline" "--locked" "--config" "source.crates-io.replace-with=\"vendored-sources\"" "--config" \
      "source.vendored-sources.directory=\"vendor\"" "--config" "git-kbvm/.cargo-source.toml" "--release" "--target" $triple "--package" "seatd" "--bin" "seatd"
  }

  fs.install(fp"target/{triple}/release/seatd", fp"{dest}/usr/bin/seatd", 0o755, parents: true, overwrite: true)

  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/seatd.xsh", 0o644, parents: true, overwrite: true)
}
