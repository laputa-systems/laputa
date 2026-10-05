##! Package recipe metadata and build operations.
use pm.util as pm_util

error SudoRsBuildError = MissingRustStd(path: Str) | MissingVendoredCrate(name: Str)

## Package recipe export.
export const name = "sudo-rs"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.2.15"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps = ["linux-pam", "gnu-stubs", "musl"]

## Package recipe export.
export const mkdeps_host = ["cargo", "llvm-toolchain", "linux-pam"]

# The build is offline: every crate sudo-rs's shipped Cargo.lock pins is an
# upstream source of its own, cached by `make fetch` and staged under vendor/,
# and cargo reads that directory instead of crates.io. The crate entries are
# exactly the `[[package]]` records with a `checksum` in the sudo-rs crate's
# Cargo.lock (crates.io serves each `.crate` with that sha256), so they are what
# `cargo vendor --locked` would produce. After a version bump, list the new
# Cargo.lock's records here.
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://static.crates.io/crates/sudo-rs/sudo-rs-VERSION.crate",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "2feba7868bd3c057f8362302112d00a18fd6ff458baa3c779c9254b761052a87",
      },
      {
        arch: "x86_64",
        sha256: "2feba7868bd3c057f8362302112d00a18fd6ff458baa3c779c9254b761052a87",
      },
    ],
  },
  {
    source: p"https://static.crates.io/crates/glob/glob-0.3.4.crate => vendor/glob-0.3.4",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "e4eba85ea1d0a966a983acd07deee566e67395d2d96b6fb39e62b5a833f1eb0b",
      },
      {
        arch: "x86_64",
        sha256: "e4eba85ea1d0a966a983acd07deee566e67395d2d96b6fb39e62b5a833f1eb0b",
      },
    ],
  },
  {
    source: p"https://static.crates.io/crates/libc/libc-0.2.189.crate => vendor/libc-0.2.189",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "3eaf3ede3fee6db1a4c2ee091bf8a8b4dccdc6d17f656fb07896ee72867612f2",
      },
      {
        arch: "x86_64",
        sha256: "3eaf3ede3fee6db1a4c2ee091bf8a8b4dccdc6d17f656fb07896ee72867612f2",
      },
    ],
  },
  {
    source: p"https://static.rust-lang.org/dist/2026-10-01/rust-std-1.99.0-ARCH-unknown-linux-musl.tar.xz => rust-std",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "ea8fd309578a09c9e12401621a470e6d6b1047f25933207fb8a39d66647d4561",
      },
      {
        arch: "x86_64",
        sha256: "b106b0aa4565cc3525fd3161c69203a9e39044e6e6b4d618f261c3eeda14ad50",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/bin/su",
    kind: "binary",
  },
  {
    path: p"usr/bin/sudo",
    kind: "binary",
  },
  {
    path: p"usr/bin/sudoedit",
    kind: "symlink",
  },
]

pure rust_triple(arch: Str) -> Str {
  return "aarch64-unknown-linux-musl" when arch == "aarch64" or arch == "arm64"

  return "x86_64-unknown-linux-musl" when arch == "amd64"

  f"{arch}-unknown-linux-musl"
}

proc stage_rustlib(source: Path, dest: Path) {
  dest.remove(missing_ok: true)
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
      out.remove(missing_ok: true)
      fs.symlink(entry.path.readlink()?, out)
    }
  }
}

type LockedCrate = {name: Str, version: Str, checksum: Str}

# Reads the registry packages from Cargo.lock. Its `[[package]]` records are
# flat `key = "value"` lines, so no TOML parser is needed.
proc locked_registry_crates(lockfile: Path) -> Result[List[LockedCrate]] {
  var crates: List[LockedCrate] = []
  var current: LockedCrate = LockedCrate(name: "", version: "", checksum: "")

  for raw in lockfile.read_lines()?.push("[[package]]") {
    let line = raw.trim()

    if line == "[[package]]" {
      if current.checksum != "" {
        crates += [current]
      }

      current = {name: "", version: "", checksum: ""}
    } else if let [_, key, value] = rx"""^(name|version|checksum) = "([^"]*)"$""".captures(line) {
      if key == "name" {
        current = {...current, name: value}
      } else if key == "version" {
        current = {...current, version: value}
      } else {
        current = {...current, checksum: value}
      }
    }
  }

  crates
}

# Cargo's directory sources require `.cargo-checksum.json` beside each crate;
# its `package` digest must match the Cargo.lock checksum, and an empty `files`
# map skips per-file verification of the already sha256-verified crate.
proc mark_vendored_crates(lockfile: Path, vendor: Path) {
  for item in locked_registry_crates(lockfile)? {
    let dir = fp"{vendor}/{item.name}-{item.version}"

    if ! fp"{dir}/Cargo.toml".exists() {
      return Err(SudoRsBuildError.MissingVendoredCrate(f"{item.name}-{item.version}"))
    }

    json.write(fp"{dir}/.cargo-checksum.json", {files: {}, package: item.checksum})
  }
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cargo = process.which("cargo")?
  let cc = process.which("cc")?
  let target_arch = pm_util.target_arch()?
  let build_root = fp"{e"XSH_PM_BUILD_ROOT" ?? ""}"
  let target_root_value = (e"LAPUTA_ROOT" ?? e"XSH_PM_ROOT" ?? "").trim()
  let target_root = if target_root_value != "" { fp"{target_root_value}" } else { cc.parent.parent }
  var libdir = fp"{target_root}/usr/lib"

  if ! libdir.exists() {
    libdir = fp"{cc.parent.parent}/lib"
  }

  let build_arch = pm_util.build_arch()?
  let triple = rust_triple(target_arch)
  let host_triple = rust_triple(build_arch)
  let host_cc = if fp"{build_root}/usr/bin/cc".exists() { fp"{build_root}/usr/bin/cc" } else { cc }
  let host_libdir = fp"{build_root}/usr/lib"
  let target_rustlib = fp"rust-std/rust-std-{triple}/lib/rustlib/{triple}"
  let staged_rustlib = fp"{target_root}/usr/lib/rustlib/{triple}"

  if ! fp"{staged_rustlib}/lib".exists() {
    guard target_rustlib.exists() else {
      return Err(SudoRsBuildError.MissingRustStd(target_rustlib.display()))
    }

    stage_rustlib(target_rustlib, staged_rustlib)
  }

  let target_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={cc} -L native={libdir} -C link-arg=-Wl,--as-needed -C link-arg=-Wl,-rpath,/usr/lib"
  let host_rustflags = f"-C panic=abort -C target-feature=-crt-static -C linker={host_cc} -L native={host_libdir} -C link-arg=-Wl,--as-needed"
  let aarch64_rustflags = if triple == "aarch64-unknown-linux-musl" { target_rustflags } else { host_rustflags }

  let x86_64_rustflags = if host_triple == "x86_64-unknown-linux-musl" and triple != host_triple {
    host_rustflags
  } else {
    target_rustflags
  }

  let aarch64_linker = if triple == "aarch64-unknown-linux-musl" { cc.display() } else { host_cc.display() }
  let x86_64_linker = if triple == "x86_64-unknown-linux-musl" { cc.display() } else { host_cc.display() }
  mark_vendored_crates(p"Cargo.lock", p"vendor")
  let current_path = e"PATH" ?? ""
  let cargo_path = f"{host_cc.parent}:{current_path}"

  env ({
    PATH: cargo_path,
    CC: host_cc.display(),
    HOST_CC: host_cc.display(),
    CARGO_HOME: fp"{fs.cwd()?}/.cargo-home".display(),
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER: aarch64_linker,
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER: x86_64_linker,
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: aarch64_rustflags,
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: x86_64_rustflags,
  }) {
    run $cargo build "--offline" "--locked" "--config" "source.crates-io.replace-with=\"vendored-sources\"" "--config" "source.vendored-sources.directory=\"vendor\"" "--release" "--target" $triple "--bin" "sudo" "--bin" "su"
  }

  fs.install(fp"target/{triple}/release/sudo", fp"{dest}/usr/bin/sudo", 0o4755, parents: true, overwrite: true)
  fs.install(fp"target/{triple}/release/su", fp"{dest}/usr/bin/su", 0o4755, parents: true, overwrite: true)
  fp"{dest}/usr/bin/sudoedit".symlink(to: p"sudo")
}
