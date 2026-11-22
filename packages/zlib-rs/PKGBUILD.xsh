##! XSH module `zlib-rs` candidate package and build operations.
use packages.upstream_pins
use pm.rust as pm_rust
use pm.target as pm_target
use pm.types

## Package recipe export.
export const name = "zlib-rs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
## Fork commit 496c33cd8c5f3fa2ef688498533981d22a07593f of laputa-systems/zlib-rs
## (zlib-rs 0.6.8, libz-rs-sys C API). The package is a promotion candidate:
## no profile installs it and it installs under usr/lib/zlib-rs so it never
## shares a path with the zlib package.
export const ver = "0.6.8"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## Package recipe export.
export let mkdeps_target = []

## Exported declaration `upstream_sources`.
## The cdylib crate has its own lockfile; its only registry crate is libc,
## which the `gz` feature needs for the gz* exports.
export let upstream_sources = [
  {
    source: p"https://github.com/laputa-systems/zlib-rs/archive/496c33cd8c5f3fa2ef688498533981d22a07593f.tar.gz => source",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "c89fab88035451291ebc544d4d6080d1433dc2565e72737f14ca7109814e57f1",
      },
    ],
  },
  {
    source: p"https://raw.githubusercontent.com/laputa-systems/zlib-rs/496c33cd8c5f3fa2ef688498533981d22a07593f/libz-rs-sys-cdylib/Cargo.lock => vendor",
    kind: "cargo-vendor",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "7fc368dd6f0c02d6c385691ae9179a1e1935f7ec8cb7006b1049d398df0402c7",
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
    path: p"usr/include/zlib-rs/zconf.h",
    kind: "file",
  },
  {
    path: p"usr/include/zlib-rs/zlib.h",
    kind: "file",
  },
  {
    path: p"usr/lib/zlib-rs/libz.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/zlib-rs/libz.so.1",
    kind: "binary",
  },
  {
    path: p"usr/share/licenses/zlib-rs/LICENSE",
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
  let checkout = fp"{root}/source"
  let project = fp"{checkout}/libz-rs-sys-cdylib"
  let _ = fs.copy_tree(fp"{root}/vendor", fp"{project}/vendor", parents: true, overwrite: true)?

  let triple = pm_target.rust_triple(target)?
  let host_cc = if fp"{build_root}/usr/bin/cc".exists() { fp"{build_root}/usr/bin/cc" } else { cc }
  let target_rustlib = fp"{root}/rust-std/rust-std-{triple}/lib/rustlib/{triple}"
  let staged_rustlib = fp"{target_root}/usr/lib/rustlib/{triple}"

  if ! fp"{staged_rustlib}/lib".exists() {
    guard target_rustlib.exists() else {
      fail "missing target standard library; check the rust-std source pin"
    }

    pm_rust.rust_stage_standard_library(target_rustlib, staged_rustlib)
  }

  # Rust cannot version symbols, so cargo builds a static archive that the C
  # linker turns into libz.so.1 under the fork's zlib.map version script. The
  # cdylib profile already sets panic=abort, which the crate enforces.
  let cargo_path = f"{host_cc.parent}:{e"PATH" ?? ""}"
  let command = process.command_argv(
    cargo,
    [cargo, "rustc", "--offline", "--locked", "--config", "source.crates-io.replace-with=\"vendored-sources\"", "--config", "source.vendored-sources.directory=\"vendor\"", "--config", "profile.release.lto=\"fat\"", "--config", "profile.release.opt-level=3", "--config", "profile.release.codegen-units=1", "--config", "profile.release.debug=false", "--release", "--target", triple, "--features", "gz", "--lib", "--crate-type", "staticlib"],
    project,
    {
      PATH: cargo_path,
      CC: host_cc,
      HOST_CC: host_cc,
      CARGO_HOME: fp"{root}/.cargo-home",
    },
  )
  let status = process.run(command)?

  guard status.ok else {
    fail "zlib-rs build failed"
  }

  let static_archive = fp"{project}/target/{triple}/release/libz_rs.a"
  let shared = fp"{root}/libz.so.1"
  run $cc "-shared" "-Wl,--gc-sections" "-static-libgcc" "-Wl,--exclude-libs=libunwind.a" "-Wl,--as-needed" "-Wl,--whole-archive" $static_archive "-Wl,--no-whole-archive" f"-Wl,--version-script={project}/include/zlib.map" "-Wl,--undefined-version" "-Wl,-soname,libz.so.1" f"-L{libdir}" "-lgcc_s" "-lc" "-o" $shared

  fs.install(shared, fp"{dest}/usr/lib/zlib-rs/libz.so.1", 0o755, parents: true, overwrite: true)
  fp"{dest}/usr/lib/zlib-rs/libz.so".symlink(to: fp"libz.so.1")
  fs.install(fp"{project}/include/zlib.h", fp"{dest}/usr/include/zlib-rs/zlib.h", 0o644, parents: true, overwrite: true)
  fs.install(fp"{project}/include/zconf.h", fp"{dest}/usr/include/zlib-rs/zconf.h", 0o644, parents: true, overwrite: true)
  fs.install(fp"{checkout}/LICENSE", fp"{dest}/usr/share/licenses/zlib-rs/LICENSE", 0o644, parents: true, overwrite: true)
}
