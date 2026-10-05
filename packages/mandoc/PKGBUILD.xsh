##! Package recipe metadata and build operations.
use pm.make
use pm.util as pm_util

## Package recipe export.
export const name = "mandoc"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## Package recipe export.
export const ver = "1.14.6"

## Package recipe export.
export const rel = "1"

## makewhatis reads gzipped pages through zlib.
export const deps = ["musl", "zlib"]

## Package recipe export.
export const mkdeps_host = ["llvm-toolchain"]

## Package recipe export.
export const upstream_sources = [
  {
    source: p"https://mandoc.bsd.lv/snapshots/mandoc-VERSION.tar.gz",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "8bf0d570f01e70a6e124884088870cbed7537f36328d512909eb10cd53179d9c",
      },
    ],
  },
]

# man, apropos, whatis, and makewhatis are mandoc itself: it selects its mode
# from argv[0], so upstream installs them as links to one binary.
const mandoc_links = ["man", "apropos", "whatis", "makewhatis"]

## Package recipe export.
export const filetree = [
  {
    path: p"usr/bin/mandoc",
    kind: "binary",
  },
  {
    path: p"usr/bin/demandoc",
    kind: "binary",
  },
  {
    path: p"usr/bin/soelim",
    kind: "binary",
  },
  {
    path: p"usr/bin/man",
    kind: "symlink",
  },
  {
    path: p"usr/bin/apropos",
    kind: "symlink",
  },
  {
    path: p"usr/bin/whatis",
    kind: "symlink",
  },
  {
    path: p"usr/bin/makewhatis",
    kind: "symlink",
  },
  {
    path: p"usr/share/man",
    kind: "tree",
  },
  {
    path: p"usr/share/man/man1/whatis.1",
    kind: "symlink",
  },
]

# The config.h that `./configure` writes for musl with clang, captured on a
# musl host from a configure.local of UTF8_LOCALE=C.UTF-8, PREFIX=/usr,
# SBINDIR=/usr/bin, and MANDIR=/usr/share/man. Every value is a libc feature
# test, so it holds for every musl target. musl lacks fts, ohash,
# getprogname, recallocarray, and strtonum, which the compat_* objects
# provide (soelim also takes compat_stringlist).
const config_h = """#ifdef __cplusplus
#error "Do not use C++.  See the INSTALL file."
#endif

#define _GNU_SOURCE
#include <sys/types.h>

#define MAN_CONF_FILE "/etc/man.conf"
#define MANPATH_BASE "/usr/share/man:/usr/X11R6/man"
#define MANPATH_DEFAULT "/usr/share/man:/usr/X11R6/man:/usr/local/man"
#define OSENUM MANDOC_OS_OTHER
#define UTF8_LOCALE "C.UTF-8"
#define EFTYPE EINVAL

#define HAVE_DIRENT_NAMLEN 0
#define HAVE_ENDIAN 1
#define HAVE_ERR 1
#define HAVE_FTS 0
#define HAVE_FTS_COMPARE_CONST 0
#define HAVE_GETLINE 1
#define HAVE_GETSUBOPT 1
#define HAVE_ISBLANK 1
#define HAVE_LESS_T 1
#define HAVE_MKDTEMP 1
#define HAVE_MKSTEMPS 1
#define HAVE_NTOHL 1
#define HAVE_PLEDGE 0
#define HAVE_PROGNAME 0
#define HAVE_REALLOCARRAY 1
#define HAVE_RECALLOCARRAY 0
#define HAVE_REWB_BSD 0
#define HAVE_REWB_SYSV 1
#define HAVE_SANDBOX_INIT 0
#define HAVE_STRCASESTR 1
#define HAVE_STRINGLIST 0
#define HAVE_STRLCAT 1
#define HAVE_STRLCPY 1
#define HAVE_STRNDUP 1
#define HAVE_STRPTIME 1
#define HAVE_STRSEP 1
#define HAVE_STRTONUM 0
#define HAVE_SYS_ENDIAN 0
#define HAVE_VASPRINTF 1
#define HAVE_WCHAR 1
#define HAVE_OHASH 0
#define NEED_XPG4_2 0

#define BINM_APROPOS "apropos"
#define BINM_CATMAN "catman"
#define BINM_MAKEWHATIS "makewhatis"
#define BINM_MAN "man"
#define BINM_SOELIM "soelim"
#define BINM_WHATIS "whatis"
#define BINM_PAGER "less"

extern	const char *getprogname(void);
extern	void	  setprogname(const char *);
extern	void	 *recallocarray(void *, size_t, size_t, size_t);
extern	long long strtonum(const char *, long long, long long, const char **);
"""

# Object lists from the upstream Makefile: LIBMANDOC_OBJS with the compat
# objects configure selected (MANDOC_COBJS), MAIN_OBJS, DEMANDOC_OBJS, and
# soelim's SOELIM_COBJS.
const libmandoc_stems = """
man man_macro man_validate
att lib mdoc mdoc_argv mdoc_macro mdoc_state mdoc_validate st
eqn roff roff_validate tbl tbl_data tbl_layout tbl_opts
arch chars mandoc mandoc_aux mandoc_msg mandoc_ohash mandoc_xr msec preconv
read tag
compat_fts compat_ohash compat_progname compat_recallocarray compat_strtonum
"""

const mandoc_main_stems = """
eqn_html html man_html mdoc_html roff_html tbl_html
eqn_term man_term mdoc_term roff_term term term_ascii term_ps term_tab
term_tag tbl_term
dbm dbm_map mansearch
dba dba_array dba_read dba_write mandocdb
main manpath mdoc_man mdoc_markdown out tree
"""

const soelim_stems = ["compat_progname", "compat_stringlist", "soelim"]

# Pages from upstream's base-install, as (source, installed path). mandoc
# owns man7/man.7: Linux man-pages' page of that name only sources groff's
# groff_man(7), so the man-pages recipe leaves it out.
const manuals = [
  ["mandoc.1", "man1/mandoc.1"],
  ["demandoc.1", "man1/demandoc.1"],
  ["soelim.1", "man1/soelim.1"],
  ["man.1", "man1/man.1"],
  ["apropos.1", "man1/apropos.1"],
  ["man.conf.5", "man5/man.conf.5"],
  ["mandoc.db.5", "man5/mandoc.db.5"],
  ["man.7", "man7/man.7"],
  ["mdoc.7", "man7/mdoc.7"],
  ["roff.7", "man7/roff.7"],
  ["eqn.7", "man7/eqn.7"],
  ["tbl.7", "man7/tbl.7"],
  ["mandoc_char.7", "man7/mandoc_char.7"],
  ["makewhatis.8", "man8/makewhatis.8"],
]

pure c_sources(stems: Str) -> List[Path] {
  [fp"{stem}.c" for stem in stems.words()]
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let cc = process.which("cc")?
  let triple = f"{pm_util.target_arch()?}-linux-musl"
  fs.write(p"config.h", config_h)
  let cflags = ["-O2", "-Wno-unused-parameter"]

  let libmandoc = make.c_static_library({
    cc,
    triple,
    cflags,
    defs: [],
    includes: [],
    root: p".",
    sources: c_sources(libmandoc_stems),
    out_dir: p"obj/libmandoc",
    out: p"obj/libmandoc.a",
    deps: [],
  })

  let libmandoc_deps = [libmandoc.output.display()]

  let mandoc = make.c_program({
    cc,
    triple,
    cflags,
    defs: [],
    includes: [],
    root: p".",
    sources: c_sources(mandoc_main_stems),
    out_dir: p"obj/mandoc",
    out: p"obj/mandoc-bin",
    libs: [libmandoc.output],
    ldflags: ["-lz"],
    deps: libmandoc_deps,
  })

  let demandoc = make.c_program({
    cc,
    triple,
    cflags,
    defs: [],
    includes: [],
    root: p".",
    sources: [p"demandoc.c"],
    out_dir: p"obj/demandoc",
    out: p"obj/demandoc-bin",
    libs: [libmandoc.output],
    ldflags: ["-lz"],
    deps: libmandoc_deps,
  })

  let soelim = make.c_program({
    cc,
    triple,
    cflags,
    defs: [],
    includes: [],
    root: p".",
    sources: [fp"{stem}.c" for stem in soelim_stems],
    out_dir: p"obj/soelim",
    out: p"obj/soelim-bin",
    libs: [],
    ldflags: [],
    deps: [],
  })

  make.run_tasks([@libmandoc.tasks, @mandoc.tasks, @demandoc.tasks, @soelim.tasks], make.jobs()?)

  let bindir = fp"{dest}/usr/bin"
  fs.install(mandoc.output, fp"{bindir}/mandoc", 0o755, parents: true, overwrite: true)
  fs.install(demandoc.output, fp"{bindir}/demandoc", 0o755, overwrite: true)
  fs.install(soelim.output, fp"{bindir}/soelim", 0o755, overwrite: true)

  for link in mandoc_links {
    fs.symlink(p"mandoc", fp"{bindir}/{link}")
  }

  let mandir = fp"{dest}/usr/share/man"

  for manual in manuals {
    fs.install(fp"{manual[0]}", fp"{mandir}/{manual[1]}", 0o644, parents: true, overwrite: true)
  }

  fs.symlink(p"apropos.1", fp"{mandir}/man1/whatis.1")
}
