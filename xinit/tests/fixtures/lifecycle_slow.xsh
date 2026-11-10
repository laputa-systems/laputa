##! Lifecycle graph service fixture.
## The service record.
export let service = {
  name: "r1-slow",
  kind: "longrun",
  command: process.command_argv(p"/bin/xsh", ["/bin/xsh", "/etc/r1/worker.xsh", "r1-slow", "slow"]),
  targets: [
    "r1",
  ],
  readiness: "notify",
  ready_timeout_ms: 400,
  stop_timeout_ms: 500,
  restart: {
    mode: "never",
  },
  logging: "off",
}
