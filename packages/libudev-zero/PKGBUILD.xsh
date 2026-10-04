##! XSH module `PKGBUILD` package and build operations.
use pm.make as make
use pm.util as pm_util

## Exported declaration `name`.
export const name = "libudev-zero"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "1.0.5"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain", "linux-headers"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/illiliti/libudev-zero/archive/VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "bf4372f79ddbe6b0e266a3d2994ffac7018a7edf4f87632aecb5176565d96138",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/include/libudev.h",
    kind: "file",
  },
  {
    path: p"usr/lib/libudev.so",
    kind: "symlink",
  },
  {
    path: p"usr/lib/libudev.so.1",
    kind: "binary",
  },
  {
    path: p"usr/lib/pkgconfig/libudev.pc",
    kind: "file",
  },
]

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let arch = pm_util.target_arch()?
  let triple = f"{arch}-linux-musl"
  # Flags from the Makefile's XCFLAGS with PREFIX=/usr. libudev looks up USB
  # vendor and product names in usb.ids and leaves them unset when it is absent.
  let cflags = ["-std=c99", "-Wall", "-Wextra", "-Wpedantic", "-Wmissing-prototypes", "-Wstrict-prototypes", "-Wno-unused-parameter"]
  let defs = ["-D_XOPEN_SOURCE=700", "-DUSB_IDS_PATH=\"/usr/share/hwdata/usb.ids\""]
  let includes = []
  let srcs = [p"udev.c", p"udev_list.c", p"udev_device.c", p"udev_monitor.c", p"udev_enumerate.c"]

  let libudev = make.c_shared_library({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: p".",
    sources: srcs,
    out_dir: p"obj",
    out: p"obj/libudev.so.1",
    soname: "libudev.so.1",
    ldflags: [],
    deps: [],
  })

  make.run_tasks(libudev.tasks, make.jobs()?)?
  fs.install(libudev.output, fp"{dest}/usr/lib/libudev.so.1", 0o755, parents: true, overwrite: true)?
  fs.symlink(p"libudev.so.1", fp"{dest}/usr/lib/libudev.so")?
  fs.install(p"udev.h", fp"{dest}/usr/include/libudev.h", 0o644, parents: true, overwrite: true)?
  fs.mkdir(fp"{dest}/usr/lib/pkgconfig")?

  fs.write(
    fp"{dest}/usr/lib/pkgconfig/libudev.pc",
    """prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libudev-zero
Description: Daemonless replacement for libudev
Version: 251
Libs: -L\${libdir} -ludev
Cflags: -I\${includedir}
""",
  )?
}
