##! The terminfo database in ncurses' directory layout,
##! `/usr/share/terminfo/<first character>/<name>`, compiled without ncurses by
##! the XSH `tic`: every entry of ncurses 6.6's misc/terminfo.src, then foot's
##! own `foot` and `foot-direct` from the foot release Laputa ships.
## Package recipe export.
export const name = "terminfo"

## Explicit payload or metapackage classification.
export const package_kind = "payload"

## The ncurses release whose terminfo.src this database compiles.
export const ver = "6.6"

## Package recipe export.
export const rel = "1"

## Package recipe export.
export const deps: List[Str] = []

## Package recipe export.
export const mkdeps_host = ["tic"]

## ncurses' terminfo.src, and foot's foot.info from the same foot release as
## `foot-minimal` (keep the two foot pins equal).
export const upstream_sources = [
  {
    source: p"https://invisible-island.net/archives/ncurses/ncurses-VERSION.tar.gz => ncurses",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11",
      },
    ],
  },
  {
    source: p"https://codeberg.org/dnkl/foot/archive/1.27.0.tar.gz => foot",
    kind: "auto",
    architectures: [
      "all",
    ],
    checksums: [
      {
        arch: "all",
        sha256: "f5917cad2d7b723b99873e53d78fd10ea202923d189aed5086591fc53b70b7e3",
      },
    ],
  },
]

## Package recipe export.
export const filetree = [{path: p"usr/share/terminfo", kind: "tree"}]

error TerminfoSourceError = Unexpected(file: Str, message: Str)

# ncurses' configure edits terminfo.src before installing it: on Linux, where
# xterm's backspace key sends DEL, the xterm+kbs fragment says so.  This is
# the `--with-xterm-kbs=DEL` edit of misc/run_tic.sed; its tabset-path edit is
# the identity for the /usr prefix.
proc linux_terminfo_source(text: Str) [error] -> Result[Str] {
  let fragment = "xterm+kbs|fragment for backspace key,\n\tkbs=^H,\n"
  guard fragment in text else {
    return Err(TerminfoSourceError.Unexpected("terminfo.src", "the xterm+kbs fragment no longer reads kbs=^H"))
  }

  text.replace(fragment, "xterm+kbs|fragment for backspace key,\n\tkbs=^?,\n")
}

# foot's meson substitutes its terminfo base name into foot.info before
# compiling it; Laputa keeps foot's default name.
proc foot_terminfo_source(text: Str) [error] -> Result[Str] {
  guard "@default_terminfo@|foot terminal emulator," in text else {
    return Err(TerminfoSourceError.Unexpected("foot.info", "the foot entry is no longer named @default_terminfo@"))
  }

  text.replace("@default_terminfo@", "foot")
}

## Package recipe export.
export proc build(dest: Path) [fs, process, env, error] {
  let tic = process.which("tic")?
  let database = fp"{dest}/usr/share/terminfo"
  p"terminfo.src".write(linux_terminfo_source(p"ncurses/misc/terminfo.src".read_text()?)?)?
  p"foot.info".write(foot_terminfo_source(p"foot/foot.info".read_text()?)?)?

  run $tic -x -o $database terminfo.src
  # foot's own descriptions replace ncurses' copies of `foot` and
  # `foot-direct`: they are released with foot itself, so they describe the
  # foot Laputa ships.  `foot+base` stays ncurses' fragment.
  run $tic -x -o $database -e foot,foot-direct foot.info
}
