##! xinit service module for tinyland.
## The service record.
export let service = {
  name: "tinyland",
  kind: "longrun",
  command: process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/laputa/tinyland-launch.xsh"]),
  dependencies: {need: ["seatd", "coldplug"]},
  targets: ["boot"],
  restart: {mode: "always", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000},
}
