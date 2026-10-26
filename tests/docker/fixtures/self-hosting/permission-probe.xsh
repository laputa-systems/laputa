for root in [/output, /scratch] {
  root.mkdir()?
  fs.set_owner(root, uid: 65534, gid: 65534)?
  root.chmod(0o755)?
}
let command = process.command_argv(/bin/xsh, ["/bin/xsh", "/repo/tests/docker/fixtures/self-hosting/read-inputs.xsh"])
let result = linux.run_in_namespaces(command, uid: 65534, gid: 65534, drop_groups: true)?
assert result.ok
