##! xinit service module for mdevd.
## The service record.
export let service = {
  name: "mdevd",
  kind: "longrun",
  command: process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/laputa/mdevd-launch.xsh"]),
  targets: ["boot"],
  readiness: "notify",
  restart: {mode: "always", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000},
}
