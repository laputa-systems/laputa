##! Oneshot that creates the Dropbear ed25519 host key when it is absent.
const host_key = p"/etc/dropbear/dropbear_ed25519_host_key"

## The xinit service record.
export let service = {
  name: "dropbear-keygen",
  kind: "oneshot",
  command: process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", "/usr/lib/xinit/services/dropbear-keygen.xsh"]),
  targets: [
    "boot",
  ],
  logging: "append",
}

proc main() [fs, process, env, error] {
  return when (e"XINIT_DROPBEAR_EPHEMERAL" ?? "") == "1"

  return when host_key.exists()

  let parent = host_key.parent

  if ! parent.exists() {
    parent.mkdir(true)
  }

  let bin = p"/usr/bin/dropbearkey"
  let argv = [f"{bin}", "-t", "ed25519", "-f", f"{host_key}"]
  let status = process.run(process.command_argv(bin, argv))?

  guard status.ok else {
    fail "dropbearkey failed"
  }
}
