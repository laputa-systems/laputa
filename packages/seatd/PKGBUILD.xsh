##! Package recipe metadata and build operations.
use pm.env as pm_env

## Package recipe export.
export const name = "seatd"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "0.9.3"

## Package recipe export.
export const rel = "8"

## Package recipe export.
export const deps = ["musl"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain", "linux-headers", "muon", "samurai", "pkgconf"]

## The build installs an xinit service module; xinit runs it at runtime.
export const runtime_only_deps = ["xinit"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://github.com/kennylevinsen/seatd/archive/refs/tags/VERSION.tar.gz",
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

proc patch_realtime_dependency() [fs, error] {
  let meson = p"meson.build"
  let text = fs.read_text(meson)?

  fs.write(
    meson,
    text.replace(
  """# needed for cross-compilation
realtime = meson.get_compiler('c').find_library('rt')
private_deps += realtime""",
  """# musl provides realtime interfaces in libc; avoid recording the build-env librt.
realtime = declare_dependency()""",
),
  )
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let muon = process.which("muon")?
  let jobs_flag = f"-j{cpu.count()}"
  let pc = pm_env.pkg_config_context()?
  patch_realtime_dependency()

  env ({
    LD_LIBRARY_PATH: pc.ld_library_path,
    PKG_CONFIG: pc.pkg_config,
    PKG_CONFIG_LIBDIR: pc.pkg_config_libdir,
    PKG_CONFIG_PATH: pc.pkg_config_path,
    PKG_CONFIG_SYSROOT_DIR: pc.pkg_config_sysroot,
  }) {
    run $muon "setup" pm_env.meson_prefix_arg() pm_env.meson_libdir_arg() "-Ddefault_library=shared" "-Dwerror=false" "-Dlibseat-logind=disabled" "-Dlibseat-seatd=enabled" "-Dlibseat-builtin=disabled" "-Dserver=enabled" "-Dexamples=disabled" "-Dman-pages=disabled" "build" ?
    run $muon "-C" "build" samu $jobs_flag ?

    env ({
      DESTDIR: dest,
    }) {
      run $muon "-C" "build" install ?
    }?
  }?

  fs.remove(fp"{dest}/usr/bin/seatd-launch", missing_ok: true)
  fs.install(p"service.xsh", fp"{dest}/usr/lib/xinit/services/seatd.xsh", 0o644, parents: true, overwrite: true)
}
