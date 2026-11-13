##! Oneshot that creates the OxiSH ed25519 host key when it is absent. An existing key is never touched.
## The state-disk path of the host key, beside `/etc/oxish/accounts`.
export const host_key_path = p"/etc/oxish/host_ed25519_key"

## The oxish-keygen argv for one new key pair. oxish-keygen itself refuses to replace a file.
export pure keygen_argv(host_key = host_key_path) -> List[Str] {
  ["/usr/bin/oxish-keygen", "-f", f"{host_key}", "-C", "laputa-host"]
}

## The xinit service record.
export let service = {
  name: "oxish-hostkey",
  kind: "oneshot",
  command: process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/usr/lib/xinit/services/oxish-hostkey.xsh"]),
  targets: [
    "boot",
  ],
  logging: "append",
}

proc main() [fs, process, error] {
  return when host_key_path.exists()

  let parent = host_key_path.parent

  if ! parent.exists() {
    parent.mkdir(true)
  }

  # A crash between the two files can leave only the public half; it is derived data and would
  # make oxish-keygen refuse the new pair, so it goes before the pair is made.
  fp"{host_key_path}.pub".remove()

  let argv = keygen_argv()
  let status = process.run(process.command_argv(p"/usr/bin/oxish-keygen", argv))?

  guard status.ok else {
    fail "oxish-keygen failed"
  }
}
