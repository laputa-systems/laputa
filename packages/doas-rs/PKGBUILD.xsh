##! XSH module `doas-rs` package and build operations.
use packages.upstream_pins as upstream_pins
use pm.target as pm_target
use pm.types

error DoasRsBuildError = MissingRustStd(path: Str)

## Package recipe export.
export const name = "doas-rs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
## The Rust port's own version.
export const ver = "0.1.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
## musl plus the GCC runtime the dynamic Rust link needs. The binary links
## libc only (the password check calls the system libcrypt in musl).
export const deps = ["musl", "gnu-stubs"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## Package recipe export.
## The Rust port lives in this monorepo as a top-level tree; the recipe
## addresses it as a `repository/` source, which the PM resolves against
## the checkout root and hashes into the plan fingerprint, so no URL pin
## is needed. The Cargo.lock pin vendors every locked crates.io crate
## beside the tree; the PM verifies each crate against Cargo.lock.
export let upstream_sources = [
  {
    source: p"repository/doas-rs",
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
    source: p"repository/doas-rs/Cargo.lock => vendor",
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
    source: fp"https://static.rust-lang.org/dist/{upstream_pins.rust_distribution_date}/rust-std-1.99.0-ARCH-unknown-linux-musl.tar.xz => rust-std",
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
    path: p"usr/bin/doas",
    kind: "binary",
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
      return Err(DoasRsBuildError.MissingRustStd(target_rustlib.display()))
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
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported doas-rs target")) }
  }

  let x86_64_rustflags = if build_target == types.target_x86_64() and target != build_target {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = match target {
    types.Aarch64LinuxMusl => cc.display()
    types.X86_64LinuxMusl => host_cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported doas-rs target")) }
  }
  let x86_64_linker = match target {
    types.Aarch64LinuxMusl => host_cc.display()
    types.X86_64LinuxMusl => cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported doas-rs target")) }
  }

  # The port carries no container cargo config; the recipe supplies its own
  # link flags below. Tolerate its absence on future pins.
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
      "source.vendored-sources.directory=\"vendor\"" "--release" "--target" $triple "--bin" "doas"
  }

  fs.install(fp"target/{triple}/release/doas", fp"{dest}/usr/bin/doas", 0o4755, parents: true, overwrite: true)
}
