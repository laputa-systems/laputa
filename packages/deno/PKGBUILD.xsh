##! Deno, the JavaScript and TypeScript runtime, built from source for musl.
use pm.env as pm_env
use pm.sources as pm_sources
use pm.util as pm_util

error DenoBuildError = V8Mismatch(locked: Str, pinned: Str)

## Package name.
export const name = "deno"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Upstream Deno release.
export const ver = "2.9.7"

## Package release revision.
export const rel = "1"

# libffi backs Deno.dlopen (the crate's own libffi build runs autotools);
# gnu-stubs' libgcc_s provides the unwinder Rust std and V8's libc++abi call.
## Runtime package dependencies.
export const deps = ["musl", "gnu-stubs", "libffi"]

## Host-side build dependencies.
export const mkdeps_host = ["cargo", "llvm-toolchain", "linux-headers"]

# Upstream publishes only glibc binaries, so Deno is built from its release
# source. V8 is not: rusty_v8 publishes a static V8 for each musl target,
# built with the `simdutf` feature Deno's workspace enables and with its own
# libc++ inside the archive. Its version must be the `v8` crate Cargo.lock
# pins, which the build checks; the rusty-v8 source URL names it too.
const rusty_v8_ver = "150.4.0"

# Every crate the release's Cargo.lock pins is a `cargo-vendor` source: `make
# fetch` caches each `.crate` by the lockfile's checksum and the build stages
# them under vendor/, so cargo runs offline. The lockfile is the same file the
# release source carries.
## Upstream sources and checksums.
export const upstream_sources = [
  {
    source: p"https://github.com/denoland/deno/releases/download/vVERSION/deno_src.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "21069d2f4dd65b6832e3f5c373c24a43a8d35cb3d68d3841e15d0582bed39ea8",
      },
    ],
  },
  {
    source: p"https://raw.githubusercontent.com/denoland/deno/vVERSION/Cargo.lock => vendor",
    kind: "cargo-vendor",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "4b501f05a28bf12c453593f0b558407890575b5f34b9dcbb2dc8e172d58a0c95",
      },
    ],
  },
  {
    source: p"https://github.com/denoland/rusty_v8/releases/download/v150.4.0/librusty_v8_simdutf_release_ARCH-unknown-linux-musl.a.gz => rusty-v8",
    kind: "file",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "aarch64",
        sha256: "54db6a6a08ea1d658fc9b406c8e7f876a62543a5aa9111f3a98b589b5d636bf6",
      },
      {
        arch: "x86_64",
        sha256: "406baa6e1a1afd68bc7a13aaa79f72b806746b88b4ba0d55479ea683032bcafd",
      },
    ],
  },
  {
    source: p"patches/deno-distribution-features.patch",
    kind: "file",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "9a91b9fc4f04ab018a65354a5d9ba67719faf7923c3346e2cd446e8351b34a5d",
      },
    ],
  },
  {
    source: p"patches/deno-musl-glibc-extensions.patch",
    kind: "file",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "9bf7e19febeabe5e8b3711ff981332704ce78f56b9d9a5c45b059417fb4d332c",
      },
    ],
  },
]

## Installed package file tree.
export const filetree = [
  {
    path: p"usr/bin/deno",
    kind: "binary",
  },
]

pure rust_triple(arch: Str) -> Str {
  return "aarch64-unknown-linux-musl" when arch == "aarch64" or arch == "arm64"

  return "x86_64-unknown-linux-musl" when arch == "amd64"

  f"{arch}-unknown-linux-musl"
}

proc ensure_locked_v8(lockfile: Path) {
  for item in pm_sources.cargo_lock_crates(lockfile)? {
    if item.name == "v8" and item.version != rusty_v8_ver {
      return Err(DenoBuildError.V8Mismatch(locked: item.version, pinned: rusty_v8_ver))
    }
  }
}

## Build the `deno` binary with cargo, offline, against the prebuilt V8.
export proc build(dest: Path) [fs, process, env, error] {
  let cargo = process.which("cargo")?
  let build_root = fp"{e"XSH_PM_BUILD_ROOT" ?? ""}"
  let bin = fp"{build_root}/usr/bin"
  let cc = fp"{bin}/cc"
  let arch = pm_util.target_arch()?
  let triple = rust_triple(arch)
  let src = fs.cwd()?
  ensure_locked_v8(p"Cargo.lock")

  # Two patches, applied in XSH (no `patch` binary):
  # deno-distribution-features drops the `upgrade` subcommand (it would
  # replace this binary with upstream's glibc build) and the zlib-ng vendoring,
  # whose libz-sys build runs cmake under ninja, and links Laputa's libffi.
  # deno-musl-glibc-extensions compiles out glibc's malloc_trim and the
  # `.init_array` hook that reads the (argc, argv, envp) arguments only glibc
  # passes; under musl it dereferences garbage before main.
  for patch_file in [
    p"deno-distribution-features.patch",
    p"deno-musl-glibc-extensions.patch",
  ] {
    let _ = patch.apply(p".", fs.read_text(patch_file)?, 1)?
  }

  let rusty_v8 = fp"{src}/rusty-v8/librusty_v8_simdutf_release_{triple}.a.gz"
  let clang_include = fp"{build_root}/usr/lib/llvm23/lib/clang/23/include"
  # bindgen (sqlite, nghttp2) drives libclang directly, not the cc wrapper,
  # so it needs the wrapper's target, sysroot, and header search order.
  let bindgen_args = [
    f"--target={arch}-linux-musl",
    f"--sysroot={build_root}",
    "-nostdinc",
    "-isystem",
    clang_include.display(),
    "-isystem",
    fp"{build_root}/usr/include".display(),
  ].join(" ")
  # The build root is both host and target, and cargo runs without
  # `--target`, so the native triple's flags cover build scripts and the
  # binary alike. Deno's own `.cargo/config.toml` adds
  # `--cfg tokio_unstable`, which these target flags join rather than replace.
  let rustflags = [
    "-C",
    "target-feature=-crt-static",
    "-C",
    f"linker={cc}",
    "-L",
    f"native={build_root}/usr/lib",
  ].join(" ")
  let jobs = if cpu.count() < 16 { cpu.count() } else { 16 }

  env ({
    PATH: f"{bin}:{e"PATH" ?? ""}",
    # Build scripts link the root's libgcc_s.so for unwinding. Without this
    # the build host's loader finds the image's libgcc_s.so, a linker script.
    LD_LIBRARY_PATH: pm_env.build_ld_library_path_env(build_root),
    CC: cc.display(),
    CXX: fp"{bin}/c++".display(),
    AR: fp"{bin}/ar".display(),
    CARGO_HOME: fp"{src}/.cargo-home".display(),
    CARGO_BUILD_JOBS: f"{jobs}",
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER: cc.display(),
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER: cc.display(),
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: rustflags,
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS: rustflags,
    # The static V8 (gzip; the build script inflates it) instead of a download.
    RUSTY_V8_ARCHIVE: rusty_v8.display(),
    LIBCLANG_PATH: fp"{build_root}/usr/lib/llvm23/lib".display(),
    BINDGEN_EXTRA_CLANG_ARGS: bindgen_args,
    # aws-lc's cc builder needs neither cmake nor perl nor go; select it
    # explicitly so a fallback to cmake fails instead.
    AWS_LC_SYS_CMAKE_BUILDER: "0",
    # Bundled zlib and xz sources compile with cc; pkg-config may only see
    # the build root, never the build host's libraries.
    LIBZ_SYS_STATIC: "1",
    LZMA_API_STATIC: "1",
    PKG_CONFIG_LIBDIR: fp"{build_root}/usr/lib/pkgconfig".display(),
    PKG_CONFIG_SYSROOT_DIR: build_root.display(),
  }) {
    run $cargo build "--offline" "--locked" "--config" "source.crates-io.replace-with=\"vendored-sources\"" "--config" "source.vendored-sources.directory=\"vendor\"" "--release" "-p" "deno" "--bin" "deno" ?
  }

  fs.install(p"target/release/deno", fp"{dest}/usr/bin/deno", 0o755, parents: true, overwrite: true)
}
