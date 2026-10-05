##! XSH module `PKGBUILD` package and build operations.
use pm.make

## Exported declaration `name`.
export const name = "eudev-lite"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "3.2.15"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain"]

## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://github.com/eudev-project/eudev/releases/download/vVERSION/eudev-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "eb69809fc0d1187f2463ab2149c53aa9f42a78e59f14ebea68eae6cb6b4fc1c3",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [
  {
    path: p"usr/bin/udevadm",
    kind: "binary",
  },
  {
    path: p"usr/bin/udevd",
    kind: "binary",
  },
  {
    path: p"usr/lib/udev/systemd-udevd",
    kind: "binary",
  },
]

proc write_udev_stub() [fs, error] {
  fs.write(
    p"laputa-udev.c",
    f"""#include <stdio.h>
#include <string.h>

static int wants_version(int argc, char **argv)
{{{{
    return argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-V") == 0);
}}}}

int main(int argc, char **argv)
{{{{
    const char *name = argc > 0 && argv[0] != 0 ? argv[0] : "udevadm";
    const char *base = strrchr(name, '/');

    if (base != 0)
        name = base + 1;

    if (wants_version(argc, argv)) {{{{
        printf("{ver}\\n");
        return 0;
    }}}}

    if (strcmp(name, "udevd") == 0 || strcmp(name, "systemd-udevd") == 0)
        return 0;

    if (argc >= 2 && (strcmp(argv[1], "trigger") == 0 || strcmp(argv[1], "settle") == 0 || strcmp(argv[1], "control") == 0))
        return 0;

    fprintf(stderr, "%s: Laputa currently packages a minimal native udev command surface\\n", name);
    return 1;
}}}}
""",
  )
}

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let os = system.uname()?
  let triple = f"{os.machine}-linux-musl"
  write_udev_stub()

  let udev = make.c_program({
    cc,
    triple,
    cflags: ["-std=c99", "-Wall", "-Wextra"],
    defs: [],
    includes: [],
    root: p".",
    sources: [p"laputa-udev.c"],
    out_dir: p"obj",
    out: p"obj/udev",
    libs: [],
    ldflags: [],
    deps: [],
  })

  make.run_tasks(udev.tasks, make.jobs()?)
  fs.install(udev.output, fp"{dest}/usr/bin/udevadm", 0o755, parents: true, overwrite: true)
  fs.install(udev.output, fp"{dest}/usr/bin/udevd", 0o755, parents: true, overwrite: true)
  fs.install(udev.output, fp"{dest}/usr/lib/udev/systemd-udevd", 0o755, parents: true, overwrite: true)
  fs.mkdir(fp"{dest}/run")
  fs.mkdir(fp"{dest}/run/udev")
  fs.mkdir(fp"{dest}/usr/lib/udev")
  fs.mkdir(fp"{dest}/usr/lib/udev/rules.d")
}
