##! xinit service for the OxiSH login-mode SSH server with a persistent ed25519 host key.
## The state-disk path of the persistent host key `oxish-hostkey` creates.
export const host_key_path = p"/etc/oxish/host_ed25519_key"
## The login-mode accounts file first boot derives from the operator and authorized keys.
export const accounts_path = p"/etc/oxish/accounts"

pure restart_policy() -> Record {
  {mode: "always", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000}
}

## The oxish-server argv. Accounts resolve in the flat `/etc/passwd` and `/etc/group`; the server
## runs as root, authenticates only, and hands each session to its sibling `oxish-session`
## (`/usr/bin`, beside the executable xinit starts) as the account.
export pure oxish_argv(
  bind = "0.0.0.0",
  port = 22,
  host_key = host_key_path,
  accounts = accounts_path,
) -> List[Str] {
  [
    "oxish-server",
    "--mode",
    "login",
    "--bind",
    bind,
    "--port",
    f"{port}",
    "--host-key-file",
    f"{host_key}",
    "--accounts",
    f"{accounts}",
    "--passwd-file",
    "/etc/passwd",
    "--group-file",
    "/etc/group",
  ]
}

let bind = e"XINIT_OXISH_BIND" ?? "0.0.0.0"
let port = (e"XINIT_OXISH_PORT" ?? "22") as Int
let configured_key = env.path("XINIT_OXISH_HOST_KEY", host_key_path)?
let host_key = if configured_key == "" { host_key_path } else { configured_key }
let configured_accounts = env.path("XINIT_OXISH_ACCOUNTS", accounts_path)?
let accounts = if configured_accounts == "" { accounts_path } else { configured_accounts }
let argv = oxish_argv(bind, port, host_key, accounts)

## The xinit service record.
export let service = {
  name: "oxish",
  kind: "longrun",
  command: process.command_argv(p"/usr/bin/oxish-server", argv),
  targets: [
    "boot",
  ],
  dependencies: {
    need: [
      "firewall",
      "oxish-hostkey",
      "net",
    ],
  },
  restart: restart_policy(),
  logging: "append",
}

## Readiness requires the supervised oxish-server child to own the configured listening socket.
export proc ready() [fs, process, env, time, error] -> Result[Bool, Error] {
  let owner = process.current_pid()?
  for listener in process.port(port)? {
    if listener.protocol == "tcp" and listener.state == "LISTEN" and listener.parent_pid == owner and listener.command == "oxish-server" and listener.local_address == bind {
      return true
    }
  }
  false
}
