##! Supervises the disposable chrony oracle.
## Chrony oracle service declaration.
export let service = {
  name: "chrony-oracle",
  kind: "longrun",
  command: process.command_argv(p"/usr/bin/xsh", ["/usr/bin/xsh", "/mnt/self-hosting/inputs/chrony-launch.xsh"]),
  readiness: "notify",
  ready_timeout_ms: 5000,
  stop_timeout_ms: 2000,
  restart: {mode: "always", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000},
  logging: "append",
}
