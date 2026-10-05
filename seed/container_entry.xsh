#!/bin/xsh
##! Run one command in a Laputa build container, then hand its writable mounts back to the host user.
# Containers run as root under rootful Docker: `make root` chroots, and recipes
# build as root. Everything a container writes into a bind mount would stay
# root-owned on the host, so `make clean` could only delete it through another
# container and host tools could not rewrite it. This entry runs the real
# command, then gives every writable mount to the uid and gid that started
# the build, whatever the command's outcome, and exits with the command's status.
#
# usage: container_entry.xsh UID GID DIR... -- COMMAND ARG...

proc give_tree(root: Path, uid: Int, gid: Int) {
  return unless fs.exists(root)?

  # The ids need not exist in the image's /etc/passwd or /etc/group.
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

  let uid = argv[0].parse_int()?
  let gid = argv[1].parse_int()?
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

main(@args)
