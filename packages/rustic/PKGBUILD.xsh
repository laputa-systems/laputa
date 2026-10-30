##! XSH module `PKGBUILD` package and build operations.
use packages.upstream_pins as upstream_pins
use pm.rust as pm_rust
use pm.target as pm_target
use pm.types

## Package recipe export.
export const name = "rustic"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
## Upstream v0.11.4. Its lockfile carries no git sources, so the standard
## cargo-vendor path applies with no PM extension.
export const ver = "0.11.4"

## Package recipe export.
export const rel = "1"

## Package recipe export.
## musl plus the GCC runtime the dynamic Rust link needs (see doas-rs).
export const deps = ["musl", "gnu-stubs"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## Package recipe export.
export let mkdeps_target = []

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/rustic-rs/rustic/archive/v0.11.4.tar.gz => source",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "ea1796a66c22e2cd0232ee4d3e18cf95c7eb8608a465481023a6422f4720d2c3",
      },
    ],
  },
  {
    source: p"https://github.com/rustic-rs/rustic/raw/v0.11.4/Cargo.lock => vendor",
    kind: "cargo-vendor",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "0446331187440b8e5971c1537eabb5eb82e22896e64ee592f2e2db89881aa84a",
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
    path: p"usr/bin/rustic",
    kind: "binary",
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

  # URL sources stage under their named directories; the crate tree lives in
  # `source` while the vendored crates land beside it. Copy the vendor tree
  # into the crate root exactly like the tailscale recipe does, so the
  # directory source resolves without network.
  let root = fs.cwd()?
  let _ = fs.copy_tree(fp"{root}/vendor", fp"{root}/source/vendor", parents: true, overwrite: true)?
  let project = fp"{root}/source"

  let build_target = pm_target.build_target()?
  let triple = pm_target.rust_triple(target)?
  let host_triple = pm_target.rust_triple(build_target)?
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

  # Same dynamic-CRT link as doas-rs: the Laputa musl package ships libc.so
  # but no libc.a, so a fully static Rust link has no static libc to close
  # against. panic=abort keeps unwinding (and the libgcc runtime) out.
  let target_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-rpath,/usr/lib"
  let host_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={host_cc} -L native={host_libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed"
  let aarch64_rustflags = match target {
    types.Aarch64LinuxMusl => target_rustflags
    types.X86_64LinuxMusl => host_rustflags
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported rustic target")) }
  }

  let x86_64_rustflags = if build_target == types.target_x86_64() and target != build_target {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = match target {
    types.Aarch64LinuxMusl => cc.display()
    types.X86_64LinuxMusl => host_cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported rustic target")) }
  }
  let x86_64_linker = match target {
    types.Aarch64LinuxMusl => host_cc.display()
    types.X86_64LinuxMusl => cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported rustic target")) }
  }

  let current_path = e"PATH" ?? ""
  let cargo_path = f"{host_cc.parent}:{current_path}"

  # The port carries no container cargo config; the recipe supplies its own
  # link flags below. Tolerate its absence on future pins.
  fp"{project}/.cargo/config.toml".remove()

  let command = process.command_argv(
    cargo,
    [cargo.display(), "build", "--offline", "--locked", "--no-default-features", "--config", "source.crates-io.replace-with=\"vendored-sources\"", "--config", "source.vendored-sources.directory=\"vendor\"", "--release", "--target", triple, "--bin", "rustic"],
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
    fail "rustic build failed"
  }

  fs.install(fp"{project}/target/{triple}/release/rustic", fp"{dest}/usr/bin/rustic", 0o755, parents: true, overwrite: true)
}
