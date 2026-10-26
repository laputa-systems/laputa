#!/bin/xsh

let status = process.run(process.command_argv(
  /usr/bin/xsh,
  ["/usr/bin/xsh", "/usr/lib/laputa/qemu-self-hosting-proof.xsh"],
  env: {XSH_MODULE_PATH: "/usr/lib/pm:/usr/lib/xsh/core"},
))?
exit status.shell_code()?
