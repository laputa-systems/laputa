##! XSH module `tinyland` package and build operations.
use pm.target as pm_target
use pm.types
use pm.util as pm_util

error TinylandBuildError = MissingRustStd(path: Str)

## Package recipe export.
export const name = "tinyland"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.1.0"

## Package recipe export.
export const rel = "1"

## Package recipe export.
## musl and the shared client libraries tinyland links: the seatd-rs daemon
## package ships the libseat client for the seatd-only broker session,
## libxkbcommon for keymaps, gnu-stubs for the CRT objects and libgcc_s
## the dynamic link needs.
export const deps = ["musl", "gnu-stubs", "libxkbcommon", "seatd-rs"]

## XKB data is a runtime lookup, not a link input.
export const runtime_only_deps = ["xkeyboard-config"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain"]

## Package recipe export.
## The source tarball and Cargo.lock pin the qualified upstream commit
## (GitHub prerelease workflow, green tests plus musl build; e40d653 adds
## the dispatch hangup check that makes daemon loss fatal, 7079c66 survives
## single keyboard loss). The cargo-vendor entry vendors every locked
## crates.io crate beside the extracted tree; the PM verifies each crate
## against Cargo.lock.
export const upstream_sources = [
  {
    source: p"https://github.com/laputa-systems/tinyland/archive/7079c665740365dbbc5a2e5b1b3ced0b56b377bb.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "0be08d4e345e757499eeec156596f38e710d3a1bc4631ad50441e5dbda2c88f0",
      },
    ],
  },
  {
    source: p"https://raw.githubusercontent.com/laputa-systems/tinyland/7079c665740365dbbc5a2e5b1b3ced0b56b377bb/Cargo.lock => vendor",
    kind: "cargo-vendor",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f07572d3e86361e635713de20d4b8e1d7f698b8405bae4e10e1bce3d3182df1e",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/bin/tinyland", kind: "binary"}]

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
      return Err(TinylandBuildError.MissingRustStd(target_rustlib.display()))
    }

    stage_rustlib(target_rustlib, staged_rustlib)
  }

  # panic=abort keeps unwinding (and the libgcc runtime) out of the image.
  # -crt-static selects the dynamic CRT (with an INTERP) like the harness
  # build: a static-PIE binary must not carry DT_NEEDED entries, and the
  # proof's explicit-loader run is only sound for real dynamics.
  # The xkbcommon crate requests its native link without a kind, which
  # rustc resolves statically; the image ships only the shared library,
  # so the vendored crate is patched to a dylib link below (the harness
  # instead links the proof-only static archive).
  let target_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-rpath,/usr/lib"
  let host_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={host_cc} -L native={host_libdir} -C link-arg=-static-libgcc -C link-arg=-Wl,--as-needed"
  let aarch64_rustflags = match target {
    types.Aarch64LinuxMusl => target_rustflags
    types.X86_64LinuxMusl => host_rustflags
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported tinyland target")) }
  }

  let x86_64_rustflags = if build_target == types.target_x86_64() and target != build_target {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = match target {
    types.Aarch64LinuxMusl => cc.display()
    types.X86_64LinuxMusl => host_cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported tinyland target")) }
  }
  let x86_64_linker = match target {
    types.Aarch64LinuxMusl => host_cc.display()
    types.X86_64LinuxMusl => cc.display()
    types.TargetReserved => { return Err(types.PmError.PackageContract("unsupported tinyland target")) }
  }

  # The harness cargo config (mold linker, guest-root search paths, static
  # CRT, proof-only XKB root) does not apply inside the container toolchain;
  # the recipe supplies its own link flags below.
  p".cargo/config.toml".remove()

  # The xkbcommon crate requests its native link without a kind, which the
  # toolchain resolves statically; the image ships only the shared library.
  for entry in fs.walk(p"vendor", gitignore: false)? |> where .kind == "file" and .name == "ffi.rs" {
    if ! entry.path.display().ends_with("xkb/ffi.rs") {
      continue
    }

    var text = entry.path.read_text()?
    let patched = text.replace("#[link(name = \"xkbcommon\")]", with: "#[link(name = \"xkbcommon\", kind = \"dylib\")]")
    entry.path.write(patched)
  }

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
      "source.vendored-sources.directory=\"vendor\"" "--release" "--target" $triple "--bin" "tinyland"
  }

  fs.install(fp"target/{triple}/release/tinyland", fp"{dest}/usr/bin/tinyland", 0o755, parents: true, overwrite: true)
}
