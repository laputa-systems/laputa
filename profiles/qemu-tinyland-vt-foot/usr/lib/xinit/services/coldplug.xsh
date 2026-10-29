##! xinit service module for coldplug.
## The service record.
export let service = {
  name: "coldplug",
  kind: "oneshot",
  command: process.command_argv(/usr/bin/xsh, ["xsh", "/usr/lib/laputa/coldplug.xsh"]),
  dependencies: {need: ["mdevd"]},
  targets: ["boot"],
}
