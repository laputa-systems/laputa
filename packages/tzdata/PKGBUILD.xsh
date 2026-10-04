##! Package recipe metadata and build operations.
use pm.make as make
use pm.util as pm_util

## Package recipe export.
export const name = "tzdata"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "2026e"

## Package recipe export.
export const rel = "1"

## The payload is TZif data and text tables; nothing is linked at runtime.
export const deps: List[Str] = []

## zic is compiled for the build machine and run once; it is not shipped.
export const mkdeps_host = ["llvm-toolchain"]

# The data tarball stages at the source root and the code tarball beside it,
# because staging an archive replaces its destination directory.
## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://data.iana.org/time-zones/releases/tzdataVERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "b26882805f26aac59d5b222978e6580484b834ccdc98be89df2f05a6dc53a652",
      },
    ],
  },
  {
    source: p"https://data.iana.org/time-zones/releases/tzcodeVERSION.tar.gz => tzcode",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "cc3d27ca2a0d8399504551b920970d80af83bfb9c216e8082a15491921935d54",
      },
    ],
  },
]

## The zoneinfo tree holds the 598 TZif files zic writes (aliases from
## `backward` are hard links to their targets) and the text tables.
export const filetree = [
  {
    path: p"usr/share/zoneinfo",
    kind: "tree",
  },
]

# Upstream's `posix_only` install compiles these files after its awk scripts
# fold them into tzdata.zi; zic reads the same rules from the raw files and
# writes byte-identical TZif output, so the build needs no awk.
const zic_sources = [
  "africa",
  "antarctica",
  "asia",
  "australasia",
  "europe",
  "northamerica",
  "southamerica",
  "etcetera",
  "factory",
  "backward",
]

# Upstream installs these beside the TZif files (its TABDATA, without the
# generated tzdata.zi); leap-seconds.list is the IERS source of leapseconds.
const table_files = [
  "iso3166.tab",
  "leap-seconds.list",
  "leapseconds",
  "zone.tab",
  "zone1970.tab",
  "zonenow.tab",
]

# The Makefile's `version.h` and `tzdir.h` rules, with the release version
# and the default TZDIR and TZDEFAULT.
proc write_zic_headers() [fs, error] {
  fs.write(
    p"tzcode/version.h",
    f"""static char const PKGVERSION[]="(tzcode) ";
static char const TZVERSION[]="{ver}";
static char const REPORT_BUGS_TO[]="tz@iana.org";
""",
  )?

  fs.write(
    p"tzcode/tzdir.h",
    """#ifndef TZDEFAULT
# define TZDEFAULT "/etc/localtime" /* default zone */
#endif
#ifndef TZDIR
# define TZDIR "/usr/share/zoneinfo" /* TZif directory */
#endif
""",
  )?
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let build_arch = pm_util.build_arch()?
  var build_cc = process.which("cc")?
  var build_task_env: Record = {}

  # zic runs here, so a cross build compiles it with the build machine's
  # compiler; its output does not depend on the target.
  if build_arch != pm_util.target_arch()? {
    let build_root = fp"{env.get("XSH_PM_BUILD_ROOT") ?? ""}"
    build_cc = fp"{build_root}/usr/bin/cc"

    build_task_env = {
      XSH_MAKE_NATIVE_CROSS: "0",
      PATH: f"{build_root}/usr/bin:{build_root}/usr/lib/llvm-toolchain/bin:{env.get("PATH") ?? ""}",
      LD_LIBRARY_PATH: f"{build_root}/usr/lib:{build_root}/usr/lib/llvm23/lib",
    }
  }

  write_zic_headers()?
  fs.mkdir(p"obj")?

  let zic = make.c_program({
    cc: build_cc,
    triple: f"{build_arch}-linux-musl",
    cflags: ["-O2"],
    defs: [],
    includes: ["-Itzcode"],
    root: p".",
    sources: [p"tzcode/zic.c"],
    out_dir: p"obj/zic-objs",
    out: p"obj/zic",
    libs: [],
    ldflags: [],
    deps: [],
  })

  make.run_tasks([{...task, env: build_task_env} for task in zic.tasks], make.jobs()?)?

  let zoneinfo = fp"{dest}/usr/share/zoneinfo"
  fs.mkdir(zoneinfo, parents: true)?
  let zic_bin = zic.output
  let sources = zic_sources
  run $zic_bin "-b" "slim" "-d" $zoneinfo @sources ?

  for table in table_files {
    fs.install(fp"{table}", fp"{zoneinfo}/{table}", 0o644, overwrite: true)?
  }
}
