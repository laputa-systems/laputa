##! Package recipe for ntpd-rs.
use pm.target as pm_target
use pm.rust as pm_rust
use pm.types

error NtpdRsBuildError = MissingRustStd(path: Str)

## Package declaration.
export const name = "ntpd-rs"

## Package declaration.
export const package_kind = "payload"

## Package declaration.
export const ver = "2.0.0-alpha.20260715"

## Package declaration.
export const rel = "2"

## Package declaration.
export const deps = ["musl"]

## Package declaration.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## Package declaration.
export const runtime_only_deps = ["ca-certificates", "xinit"]

## Package declaration.
export const upstream_sources = [
  {
    source: p"repository/ntpd-rs",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"repository/ntpd-rs/Cargo.lock => vendor",
    kind: "cargo-vendor",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
  {
    source: p"launch.xsh",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "SKIP"}],
  },
  {
    source: p"ntp.toml",
    kind: "auto",
    architectures: ["all"],
    checksums: [{arch: "all", sha256: "SKIP"}],
  },
  {
    source: p"service.xsh",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "SKIP",
      },
    ],
  },
]

## Package declaration.
export const filetree = [
  {
    path: p"usr/bin/ntp-daemon",
    kind: "binary",
  },
  {
    path: p"usr/bin/ntp-ctl",
    kind: "binary",
  },
  {
    path: p"usr/bin/ntp-metrics-exporter",
    kind: "binary",
  },
  {
    path: p"usr/lib/ntpd-rs/launch.xsh",
    kind: "file",
  },
  {
    path: p"usr/share/ntpd-rs/ntp.toml",
    kind: "file",
  },
  {
    path: p"usr/lib/xinit/services/ntpd-rs.xsh",
    kind: "file",
  },
]

## Package operation.
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
      return Err(NtpdRsBuildError.MissingRustStd(target_rustlib.display()))
    }

    pm_rust.rust_stage_standard_library(target_rustlib, staged_rustlib)
  }

  let target_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed"
  let host_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={host_cc} -L native={host_libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed"
  let aarch64_rustflags = match target {
    types.Aarch64LinuxMusl => target_rustflags
    types.X86_64LinuxMusl => host_rustflags
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported ntpd-rs target")) }
  }

  let x86_64_rustflags = if build_target == types.target_x86_64() and target != build_target {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = match target {
    types.Aarch64LinuxMusl => cc.display()
    types.X86_64LinuxMusl => host_cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported ntpd-rs target")) }
  }
  let x86_64_linker = match target {
    types.Aarch64LinuxMusl => host_cc.display()
    types.X86_64LinuxMusl => cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported ntpd-rs target")) }
  }

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
      "source.vendored-sources.directory=\"vendor\"" "--release" "--jobs" "2" "--target" $triple "-p" "ntpd" "--no-default-features" "--features" "graviola,rustcrypto" "--bins"
  }

  for binary in ["ntp-daemon", "ntp-ctl", "ntp-metrics-exporter"] {
    fs.install(fp"target/{triple}/release/{binary}", fp"{dest}/usr/bin/{binary}", 0o755, parents: true, overwrite: true)
  }
  fs.install(p"launch.xsh", fp"{dest}/usr/lib/ntpd-rs/launch.xsh", 0o644, parents: true, overwrite: true)
  fs.install(p"ntp.toml", fp"{dest}/usr/share/ntpd-rs/ntp.toml", 0o644, parents: true, overwrite: true)
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/ntpd-rs.xsh", 0o644, parents: true, overwrite: true)
}
