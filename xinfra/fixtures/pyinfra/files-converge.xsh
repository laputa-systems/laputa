##! The equivalent of files-converge.py.

use infra.declare
use infra.model

## The resources one host should have.
export proc resources(host: model.Host) [fs, error] -> Result[List[model.Resource], Error] {
  [
    declare.directory(id: "dir", at: "/var/tmp/pi/dir", mode: 0o750, owner: "root", group_name: "wheel", parents: true)?,
    declare.file(id: "file", at: "/var/tmp/pi/dir/motd", text: "hello\n", mode: 0o640, owner: "root", group_name: "wheel", needs: ["dir"])?,
    declare.symlink(id: "link", at: "/var/tmp/pi/dir/current", target: "motd", needs: ["file"])?,
    declare.group_account(id: "grp", name: "pig", gid: 4401)?,
    declare.user_account(id: "usr", name: "piu", uid: 4402, primary_group: "pig", shell: "/bin/ash", home: "/home/piu", needs: ["grp"])?,
  ]
}
