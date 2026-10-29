##! XSH module `seatd-rs` package and build operations.
use pm.env as pm_env
use pm.target as pm_target
use pm.types
use pm.util as pm_util

error SeatdRsBuildError = MissingRustStd(path: Str)

## Package recipe export.
export const name = "seatd-rs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
## Daemon and client library versions move together: the Rust daemon reports
## the upstream seatd release it reimplements, and the client library is cut
## from that same C release.
export const ver = "0.9.3"

## Package recipe export.
export const rel = "1"

## Package recipe export.
## musl plus the GCC runtime the dynamic Rust link needs. The client library
## links libc only; the daemon links libc only (no libseat dependency).
export const deps = ["musl", "gnu-stubs"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain", "linux-headers", "muon", "samurai", "pkgconf"]

## The build installs an xinit service module; xinit runs it at runtime.
export const runtime_only_deps = ["xinit"]

## Package recipe export.
## The Rust daemon lives in this monorepo as a top-level tree; the recipe
## addresses it as a `repository/` source, which the PM resolves against
## the checkout root and hashes into the plan fingerprint, so no URL pin
## is needed. The Cargo.lock pin vendors every locked crates.io crate
## beside the tree; the PM verifies each crate against it.
## The C release tarball builds only the libseat client library the
## tinyland compositor links; the daemon binary always comes from Rust.
export const upstream_sources = [
  {
    source: p"repository/seatd-rs",
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
    source: p"repository/seatd-rs/Cargo.lock => vendor",
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
    source: p"https://github.com/kennylevinsen/seatd/archive/refs/tags/VERSION.tar.gz => c-seatd",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "302564d54d8e28191fadfd734f2675ecb0c9e0615a58011b89ef15dfa4dbaa96",
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
## Same installed filetree as the C `seatd` package, so the tinyland profile
## swaps one package name: the daemon binary is Rust, the client library C.
export const filetree = [
  {
    path: p"usr/bin/seatd",
    kind: "binary",
  },
  {
    path: p"usr/include/libseat.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libseat.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libseat.so.1",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libseat.pc",
    kind: "file",
  },
  {
    path: p"usr/lib/xinit/services/seatd.xsh",
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

proc patch_realtime_dependency(root: Path) {
  let meson = fp"{root}/meson.build"
  let text = meson.read_text()?

  meson.write(
    text.replace(
  """# needed for cross-compilation
realtime = meson.get_compiler('c').find_library('rt')
private_deps += realtime""",
  with: """# musl provides realtime interfaces in libc; avoid recording the build-env librt.
realtime = declare_dependency()""",
),
  )
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
      return Err(SeatdRsBuildError.MissingRustStd(target_rustlib.display()))
    }

    stage_rustlib(target_rustlib, staged_rustlib)
  }

  # panic=abort keeps unwinding (and the libgcc runtime) out of the image.
  # -crt-static selects the dynamic CRT (with an INTERP) like the tinyland
  # harness build: the Laputa musl package ships libc.so but no libc.a, so
  # a fully static Rust link has no static libc to close against.
  let target_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-rpath,/usr/lib"
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
      "source.vendored-sources.directory=\"vendor\"" "--release" "--target" $triple "--bin" "seatd"
  }

  fs.install(fp"target/{triple}/release/seatd", fp"{dest}/usr/bin/seatd", 0o755, parents: true, overwrite: true)

  # The C release builds only the libseat client library. The daemon stays
  # Rust: -Dserver=disabled drops seatd and seatd-launch from install.
  patch_realtime_dependency(p"c-seatd")

  let muon = process.which("muon")?
  let jobs_flag = f"-j{cpu.count()}"
  let pc = pm_env.pkg_config_context()?

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon "-C" "c-seatd" "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() "-Ddefault_library=shared" "-Dwerror=false" \
      "-Dlibseat-logind=disabled" "-Dlibseat-seatd=enabled" "-Dlibseat-builtin=disabled" "-Dserver=disabled" \
      "-Dexamples=disabled" "-Dman-pages=disabled" "build"
    run $muon "-C" "c-seatd/build" samu $jobs_flag

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "c-seatd/build" install
    }
  }

  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/seatd.xsh", 0o644, parents: true, overwrite: true)
}
