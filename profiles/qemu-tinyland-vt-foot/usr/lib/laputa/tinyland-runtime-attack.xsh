#!/bin/xsh
proc permission_denied(result: Result[Unit, Error]) [error] {
  match result {
    Ok(_) => { fail "unprivileged runtime attack succeeded" },
    Err(error) => {
      let code = error.errno ?? -1
      guard code == 1 or code == 13 else { return Err(error) }
    },
  }
}

proc main() [fs, process, error] {
  let attacker = user.lookup("nobody")?
  let session = user.lookup("laputa")?
  let identity = unix.id()?
  guard identity.uid == attacker.uid and identity.euid == attacker.uid else { fail "runtime attack has wrong identity" }
  permission_denied(fs.symlink(p"/etc", p"/run/user/laputa-attack"))?
  permission_denied(fs.symlink(p"/etc", fp"/run/user/{session.uid}/laputa-attack"))?
  permission_denied(fs.rename_noreplace(fp"/run/user/{session.uid}", p"/run/user/laputa-displaced"))?
}

main()
