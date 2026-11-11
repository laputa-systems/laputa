##! Boot oneshot that persists a bounded diagnostics collection.
##!
##! The service writes to the same state disk as the syslog receiver and does
##! not gate boot: a failed collection is visible in its own capture and in the
##! console markers, but rescue and login never wait for it.

## The exact collector invocation. Logging is xinit's copy-truncate capture.
export pure diagnostics_argv() -> List[Str] {
  ["xsh", "/usr/lib/laputa/diagnostics.xsh", "--phase", "boot"]
}

## The xinit service record.
export let service = {
  name: "diagnostics",
  kind: "oneshot",
  command: process.command_argv(p"/usr/bin/xsh", diagnostics_argv(), env: {XSH_MODULE_PATH: "/usr/lib/xsh/core"}),
  targets: [
    "boot",
  ],
  dependencies: {
    after: [
      "logger",
    ],
  },
  logging: "append",
}
