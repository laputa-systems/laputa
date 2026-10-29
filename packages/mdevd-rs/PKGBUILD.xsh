##! XSH module `mdevd-rs` package and build operations.
use pm.target as pm_target
use pm.types

error MdevdRsBuildError = MissingRustStd(path: Str)

## Package recipe export.
export const name = "mdevd-rs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
## The Rust port's own version; it replaces the mdevd/mdevd-coldplug pair.
export const ver = "0.1.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
## musl plus the GCC runtime the dynamic Rust link needs. Both daemons link
## libc only.
export const deps = ["musl", "gnu-stubs"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## The build installs an xinit service module; xinit runs it at runtime.
export const runtime_only_deps = ["xinit"]

## Package recipe export.
## The Rust port lives in this monorepo as a top-level tree; the recipe
## addresses it as a `repository/` source, which the PM resolves against
## the checkout root and hashes into the plan fingerprint, so no URL pin
## is needed. The Cargo.lock pin vendors every locked crates.io crate
## beside the tree; the PM verifies each crate against Cargo.lock.
export const upstream_sources = [
  {
    source: p"repository/mdevd-rs",
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
    source: p"repository/mdevd-rs/Cargo.lock => vendor",
    kind: "cargo-vendor",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "ef1bbbdae2b1d1f0857f169a81ef8d9e9174883eebdd7fbef5d8cab582f02465",
      },
    ],
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

## Package recipe export.
## Same installed filetree as the C `mdevd` package, so the tinyland profile
## swaps one package name: both binaries are Rust.
export const filetree = [
  {
    path: p"usr/bin/mdevd",
    kind: "binary",
  },
  {
    path: p"usr/bin/mdevd-coldplug",
    kind: "binary",
  },
  {
    path: p"usr/lib/xinit/services/mdevd.xsh",
    kind: "file",
  },
]

proc stage_rustlib(source: Path, dest: Path) {
  dest.remove()
  dest.mkdir()

  for entry in fs.walk(source, gitignore: false)? |> sort-by .path {
    continue when entry.path == source
    let relative = entry.path.relative_to(source)
    let out = fp"{dest}/{relative}"

    if entry.kind == "dir" {
      out.mkdir()
    } else if entry.kind == "file" {
      let mode = if entry.path.executable() { 0o755 } else { 0o644 }
      fs.install(entry.path, out, mode, parents: true, overwrite: true)
    } else if entry.kind == "symlink" {
      out.parent.mkdir()
      out.remove()
      out.symlink(to: entry.path.readlink()?)
    }
  }
}

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
      return Err(MdevdRsBuildError.MissingRustStd(target_rustlib.display()))
    }

    stage_rustlib(target_rustlib, staged_rustlib)
  }

  # panic=abort keeps unwinding (and the libgcc runtime) out of the image.
  # -crt-static selects the dynamic CRT (with an INTERP): the Laputa musl
  # package ships libc.so but no libc.a, so a fully static Rust link has no
  # static libc to close against.
  let target_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-rpath,/usr/lib"
  let host_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={host_cc} -L native={host_libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed"
  let aarch64_rustflags = match target {
    types.Aarch64LinuxMusl => target_rustflags
    types.X86_64LinuxMusl => host_rustflags
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported mdevd-rs target")) }
  }

  let x86_64_rustflags = if build_target == types.target_x86_64() and target != build_target {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = match target {
    types.Aarch64LinuxMusl => cc.display()
    types.X86_64LinuxMusl => host_cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported mdevd-rs target")) }
  }
  let x86_64_linker = match target {
    types.Aarch64LinuxMusl => host_cc.display()
    types.X86_64LinuxMusl => cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported mdevd-rs target")) }
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
      "source.vendored-sources.directory=\"vendor\"" "--release" "--target" $triple "--bin" "mdevd" "--bin" "mdevd-coldplug"
  }

  fs.install(fp"target/{triple}/release/mdevd", fp"{dest}/usr/bin/mdevd", 0o755, parents: true, overwrite: true)
  fs.install(
    fp"target/{triple}/release/mdevd-coldplug",
    fp"{dest}/usr/bin/mdevd-coldplug",
    0o755,
    parents: true,
    overwrite: true,
  )
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/mdevd.xsh", 0o644, parents: true, overwrite: true)
}
