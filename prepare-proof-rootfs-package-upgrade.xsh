proc remove_path(root: Path, rel: Path) [fs, error] {
  fs.remove(fp"${root}/${rel}", missing_ok: true)?
}

proc clean_root(root: Path) [fs, error] {
  for rel in [
    p"bin/xsh",
    p"bin/xshi",
    p"bin/xsht",
    p"usr/bin/xinit",
    p"init",
    p"usr/bin/mdev",
    p"usr/bin/getty",
    p"usr/bin/login",
    p"usr/bin/nologin",
    p"usr/bin/passwd",
    p"usr/bin/su",
    p"usr/bin/sulogin",
    p"usr/lib/xsh/core",
  ] {
    remove_path(root, rel)?
  }
}

proc main(...roots: List[Str]) [fs, error] {
  for raw in roots {
    clean_root(fp"${raw}")?
  }
}

main(@args)?
