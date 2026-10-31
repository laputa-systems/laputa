#!/bin/xsh
let cmdline = p"/proc/cmdline".read_text()?
if "LAPUTA_QEMU_TINYLAND_GHOSTTY_PROOF=1" in cmdline {
  run /usr/bin/xsh "/usr/lib/laputa/qemu-tinyland-ghostty-proof.xsh"
}
