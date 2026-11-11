##! Install xinfra under a prefix: the library and entry script under
##! PREFIX/share/xinfra and a symlink PREFIX/bin/xinfra. The runtime needs only
##! a qualified `xsh` on PATH; tests, fixtures and examples are not installed.

const runtime_files = ["xsht-config.ini"]
const runtime_dirs = ["bin", "lib"]

## Install xinfra under PREFIX.
cli main(prefix: Path) [fs, error] {
  let share = fp"{prefix}/share/xinfra"
  share.mkdir(parents: true)
  for name in runtime_files {
    fp"{name}".copy(to: fp"{share}/{name}", overwrite: true)
  }

  for name in runtime_dirs {
    let _ = fs.copy_tree(fp"{name}", fp"{share}/{name}", parents: true, overwrite: true)?
  }

  let bin = fp"{prefix}/bin"
  bin.mkdir(parents: true)
  let link = fp"{bin}/xinfra"
  link.remove(missing_ok: true)
  link.symlink(to: fp"{share}/bin/xinfra.xsh")
  print f"installed {link}"
}
