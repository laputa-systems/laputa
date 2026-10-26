#!/bin/xsh
##! Run one command in a Laputa build container, then hand its writable mounts back to the host user.

proc give_tree(root: Path, uid: Int, gid: Int) {
  return unless root.exists()

  let owner = {uid, gid, name: "", home: /, shell: ""}
  let owning_group = {gid, members: [], name: ""}
  fs.chown(root, owner, false)
  fs.chgrp(root, owning_group, false)

  for entry in fs.walk(root, hidden: true) {
    fs.chown(entry.path, owner, false)
    fs.chgrp(entry.path, owning_group, false)
  }
}

proc main(...argv: List[Str]) [fs, process, error] {
  var separator = -1

  for index in range(argv.len()) {
    if argv[index] == "--" {
      separator = index
      break
    }
  }

  guard separator >= 2 and separator + 1 < argv.len() else {
    fail "usage: container_entry.xsh UID GID DIR... -- COMMAND ARG..."
  }

  let uid = argv[0] as Int
  let gid = argv[1] as Int
  let dirs = [fp"{dir}" for dir in argv[2..separator]]
  let command = argv[separator + 1..]
  let status = run.status @command ?

  for dir in dirs {
    give_tree(dir, uid, gid)
  }

  if ! status.ok {
    exit status.exit_code() ?? 1
  }
}
