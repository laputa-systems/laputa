##! xinit service for Dropbear with a persistent ed25519 host key.
const persistent_host_key = p"/etc/dropbear/dropbear_ed25519_host_key"

pure restart_policy() -> Record {
  {mode: "always", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000}
}

## Dropbear argv. Ephemeral mode is the only path that passes -R and omits -r.
export pure dropbear_argv(bind = "0.0.0.0", port = 22, host_key = persistent_host_key, ephemeral = false) -> List[Str] {
  let listen = f"{bind}:{port}"

  if ephemeral {
    ["dropbear", "-F", "-E", "-R", "-p", listen]
  } else {
    ["dropbear", "-F", "-E", "-p", listen, "-r", f"{host_key}"]
  }
}

let bind = e"XINIT_DROPBEAR_BIND" ?? "0.0.0.0"
let port = (e"XINIT_DROPBEAR_PORT" ?? "22") as Int
let ephemeral = (e"XINIT_DROPBEAR_EPHEMERAL" ?? "") == "1"
let configured = env.path("XINIT_DROPBEAR_HOST_KEY", persistent_host_key)?
let host_key = if configured == "" { persistent_host_key } else { configured }
let argv = dropbear_argv(bind, port, host_key, ephemeral)

## The xinit service record.
export let service = {
  name: "dropbear",
  kind: "longrun",
  command: process.command_argv(/usr/bin/dropbear, argv),
  targets: [
    "boot",
  ],
  dependencies: {
    need: [
      "firewall",
      "dropbear-keygen",
      "net",
    ],
  },
  restart: restart_policy(),
  logging: "append",
}
