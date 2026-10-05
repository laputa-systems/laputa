##! XSH module `PKGBUILD` package and build operations.
use pm.make
use pm.util as pm_util

## Exported declaration `name`.
export const name = "less"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Exported declaration `ver`.
export const ver = "710"

## Exported declaration `rel`.
export const rel = "1"

## Exported declaration `deps`.
export const deps = ["musl"]

## Exported declaration `mkdeps_host`.
export const mkdeps_host = ["llvm-toolchain"]

# The release tarball ships help.c and funcs.h already generated from
# less.hlp and the sources (upstream's mkhelp.pl and mkfuncs.pl), so the build
# needs neither perl nor a generator. The patch replaces configure's
# defines.h and the curses/termcap layer: see the patch's screen.c table.
## Exported declaration `upstream_sources`.
export const upstream_sources = [
  {
    source: p"https://www.greenwoodsoftware.com/less/less-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "d1008fb78dcae1323ddab664bcb352a61f022b1b131bd8018548e021d975ec7a",
      },
    ],
  },
  {
    source: p"patches/less-builtin-terminal.patch",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "ad4237310671f963852624f172e1d4dbc8612add922be1cada5684a6906729e5",
      },
    ],
  },
]

## Exported declaration `filetree`.
export const filetree = [{path: p"usr/bin/less", kind: "binary"}, {path: p"usr/libexec/less-osc8-open", kind: "file"}]

## Exported declaration `build`.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let target_arch = pm_util.target_arch()?
  let triple = f"{target_arch}-linux-musl"

  # Laputa ships no curses library: the patch adds a checked-in defines.h in
  # place of configure's and gives screen.c built-in xterm-compatible
  # capabilities (LESS_TERMCAP_* still overrides each one).
  let _ = patch.apply(p".", p"less-builtin-terminal.patch".read_text()?, 1)?

  let cflags = ["-O2"]
  let defs = ["-DBINDIR=\"/usr/bin\"", "-DLIBEXECDIR=\"/usr/libexec\"", "-DSYSDIR=\"/etc\"", "-DSECURE_COMPILE=0"]
  let includes = ["-I."]

  # Makefile.in's OBJ list with REGEX_O empty (POSIX regcomp from libc).
  let less_srcs = [
    p"main.c",
    p"screen.c",
    p"brac.c",
    p"ch.c",
    p"charset.c",
    p"cmdbuf.c",
    p"command.c",
    p"cvt.c",
    p"decode.c",
    p"edit.c",
    p"evar.c",
    p"filename.c",
    p"forwback.c",
    p"help.c",
    p"ifile.c",
    p"input.c",
    p"jump.c",
    p"line.c",
    p"linenum.c",
    p"lmsg.c",
    p"lsystem.c",
    p"mark.c",
    p"optfunc.c",
    p"option.c",
    p"opttbl.c",
    p"os.c",
    p"output.c",
    p"pattern.c",
    p"position.c",
    p"prompt.c",
    p"search.c",
    p"signal.c",
    p"tags.c",
    p"ttyin.c",
    p"version.c",
    p"xbuf.c",
    p"lesskey_parse.c",
  ]

  let less = make.c_program({
    cc,
    triple,
    cflags,
    defs,
    includes,
    root: p".",
    sources: less_srcs,
    out_dir: p"obj/less-objs",
    out: p"obj/less",
    libs: [],
    ldflags: [],
    deps: [],
  })

  make.run_tasks(less.tasks, make.jobs()?)
  fs.install(less.output, fp"{dest}/usr/bin/less", 0o755, parents: true, overwrite: true)
  fs.install(p"less-osc8-open.sh", fp"{dest}/usr/libexec/less-osc8-open", 0o755, parents: true, overwrite: true)
}
