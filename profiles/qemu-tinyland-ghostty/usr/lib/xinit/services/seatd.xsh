##! xinit service module for seatd.
## The service record.
export let service = {
  name: "seatd",
  kind: "longrun",
  command: process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/laputa/seatd-launch.xsh"]),
  dependencies: {need: ["coldplug"]},
  targets: ["boot"],
  readiness: "notify",
  restart: {mode: "always", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000},
}
