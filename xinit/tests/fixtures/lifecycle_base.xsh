##! Lifecycle graph service fixture.
## The service record.
export let service = {
  name: "r1-base",
  kind: "longrun",
  command: process.command_argv(p"/bin/xsh", ["/bin/xsh", "/etc/r1/worker.xsh", "r1-base", "ready"]),
  targets: [
    "r1",
  ],
  readiness: "notify",
  ready_timeout_ms: 1500,
  stop_timeout_ms: 500,
  restart: {
    mode: "always",
    delay_ms: 400,
    max_delay_ms: 1600,
    stable_after_ms: 800,
  },
  logging: "off",
}
