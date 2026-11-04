##! XSH module `rust-fontconfig` package and build operations.
use packages.upstream_pins as upstream_pins
use pm.make
use pm.rust as pm_rust
use pm.target as pm_target
use pm.types

## Package recipe export.
export const name = "rust-fontconfig"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
## Upstream v5.0.2 (commit 966dc9c8187601ec4ad206a095a5f48fbe490279).
export const ver = "5.0.2"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## Package recipe export.
export let mkdeps_target = []

## Exported declaration `upstream_sources`.
## Upstream ships no Cargo.lock; `files/Cargo.lock` pins the `ffi` feature's
## resolution and vendors every locked crate.
export const upstream_sources = [
  {
    source: p"https://github.com/fschutt/rust-fontconfig/archive/v5.0.2.tar.gz => source",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "63f533566b8bcba902a8005f6f5408a6c62cbe8b979da2bcbca4090a33b38a7b",
      },
    ],
  },
  {
    source: p"files/script-chain.patch",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "11bf93f9d0ba44cfb8ee33049337e05d4a41212b050b2239d2881ab9b4a555fe",
      },
    ],
  },
  {
    source: p"files/Cargo.lock => lock",
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
    source: p"files/Cargo.lock => vendor",
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
    source: p"https://static.rust-lang.org/dist/{upstream_pins.rust_distribution_date}/rust-std-1.99.0-ARCH-unknown-linux-musl.tar.xz => rust-std",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: upstream_pins.rust_std_checksums,
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/include/rust-fontconfig/rust_fontconfig.h",
    kind: "file",
  },
  {
    path: p"usr/lib/librust_fontconfig.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/librust_fontconfig.so.5.0.2",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/rust-fontconfig.pc",
    kind: "file",
  },
  {
    path: p"usr/share/licenses/rust-fontconfig/LICENSE",
    kind: "file",
  },
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

  let root = fs.cwd()?
  let project = fp"{root}/source"
  let _ = patch.apply(project, fp"{root}/script-chain.patch".read_text()?, 1)?
  let _ = fs.copy_tree(fp"{root}/vendor", fp"{project}/vendor", parents: true, overwrite: true)?
  fs.install(fp"{root}/lock/Cargo.lock", fp"{project}/Cargo.lock", 0o644, parents: true, overwrite: true)

  let build_target = pm_target.build_target()?
  let triple = pm_target.rust_triple(target)?
  let host_cc = if fp"{build_root}/usr/bin/cc".exists() { fp"{build_root}/usr/bin/cc" } else { cc }
  let host_libdir = fp"{build_root}/usr/lib"
  let target_rustlib = fp"{root}/rust-std/rust-std-{triple}/lib/rustlib/{triple}"
  let staged_rustlib = fp"{target_root}/usr/lib/rustlib/{triple}"

  if ! fp"{staged_rustlib}/lib".exists() {
    guard target_rustlib.exists() else {
      fail "missing target standard library; check the rust-std source pin"
    }

    pm_rust.rust_stage_standard_library(target_rustlib, staged_rustlib)
  }

  let soname = f"librust_fontconfig.so.{ver}"

  # Every export contains panics with catch_unwind, so the library keeps
  # panic=unwind. -crt-static selects the dynamic CRT: the Laputa musl package
  # ships libc.so but no libc.a.
  let target_rustflags = f"-C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-soname,{soname}"
  let host_rustflags = f"-C target-feature=-crt-static -C linker={host_cc} -L native={host_libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-soname,{soname}"
  let aarch64_rustflags = match target {
    types.Aarch64LinuxMusl => target_rustflags
    types.X86_64LinuxMusl => host_rustflags
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported rust-fontconfig target")) }
  }

  let x86_64_rustflags = if build_target == types.target_x86_64() and target != build_target {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = match target {
    types.Aarch64LinuxMusl => cc.display()
    types.X86_64LinuxMusl => host_cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported rust-fontconfig target")) }
  }
  let x86_64_linker = match target {
    types.Aarch64LinuxMusl => host_cc.display()
    types.X86_64LinuxMusl => cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported rust-fontconfig target")) }
  }

  let cargo_path = f"{host_cc.parent}:{e"PATH" ?? ""}"
  let jobs = make.jobs()?
  let command = process.command_argv(
    cargo,
    [cargo.display(), "rustc", "--offline", "--locked", "--jobs", f"{jobs}", "--no-default-features", "--features", "ffi", "--config", "source.crates-io.replace-with=\"vendored-sources\"", "--config", "source.vendored-sources.directory=\"vendor\"", "--config", "profile.release.lto=\"fat\"", "--config", "profile.release.opt-level=\"s\"", "--config", "profile.release.codegen-units=1", "--release", "--target", triple, "--lib", "--crate-type", "cdylib"],
    project,
    {
      PATH: cargo_path,
      CC: host_cc.display(),
      HOST_CC: host_cc.display(),
      CARGO_HOME: fp"{root}/.cargo-home".display(),
      CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER: aarch64_linker,
      CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: aarch64_rustflags,
      CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER: x86_64_linker,
      CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: x86_64_rustflags,
    },
  )
  let status = process.run(command)?

  guard status.ok else {
    fail "rust-fontconfig build failed"
  }

  fs.install(fp"{project}/target/{triple}/release/librust_fontconfig.so", fp"{dest}/usr/lib/{soname}", 0o755, parents: true, overwrite: true)
  fp"{dest}/usr/lib/librust_fontconfig.so".symlink(to: fp"{soname}")
  fs.install(fp"{project}/ffi/rust_fontconfig.h", fp"{dest}/usr/include/rust-fontconfig/rust_fontconfig.h", 0o644, parents: true, overwrite: true)
  fs.install(fp"{project}/LICENSE", fp"{dest}/usr/share/licenses/rust-fontconfig/LICENSE", 0o644, parents: true, overwrite: true)
  fp"{dest}/usr/lib/pkgconfig".mkdir(true)
  fp"{dest}/usr/lib/pkgconfig/rust-fontconfig.pc".write(
    r"""prefix=/usr
libdir=${prefix}/lib
includedir=${prefix}/include/rust-fontconfig

Name: rust-fontconfig
Description: Pure-Rust font discovery, matching, and fallback with a C API
Version: @VERSION@
Libs: -L${libdir} -lrust_fontconfig
Cflags: -I${includedir}
""".replace("@VERSION@", with: ver),
  )
}
