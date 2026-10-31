#!/bin/xsh
proc require_directory(path_value: Path, uid: Int, gid: Int, mode: Int) [fs, error] {
  let meta = fs.stat(path_value, follow_symlinks: false)?
  guard meta.kind == "dir" and meta.uid == uid and meta.gid == gid and meta.mode % 4096 == mode else {
    fail f"unsafe runtime directory {path_value}"
  }
}

proc main() [fs, error] {
  let account = user.lookup("laputa")?
  require_directory(p"/run", 0, 0, 0o755)?
  let run_root = fs.open_root(p"/run")?
  if ! run_root.exists(p"user")? {
    run_root.mkdir(p"user", mode: 0o755)?
  }
  require_directory(p"/run/user", 0, 0, 0o755)?
  let parent = run_root.open_root(p"user")?
  let name = fp"{account.uid}".require(RelPath)?
  if ! parent.exists(name)? {
    parent.mkdir(name, mode: 0o700)?
    let runtime = fp"/run/user/{account.uid}"
    fs.set_owner(runtime, uid: account.uid, gid: account.gid, follow_symlinks: false)?
  }
  require_directory(fp"/run/user/{account.uid}", account.uid, account.gid, 0o700)?
  parent.close()?
  run_root.close()?
}

main()
