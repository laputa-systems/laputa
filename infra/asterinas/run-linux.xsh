#!/bin/xsh --
use infra.asterinas.guest_protocol
use system.qemu

cli main(kernel: Path, initramfs: Path, disk: Path, console: Path, qemu_log: Path, selection: Str, timeout_seconds: Int, memory_mib: Int, tap: Str = "") [fs, process, env, time, error] {
  let target = qemu.host_qemu_target()?
  let config = qemu.qemu_config(target)?
  let input = qemu.QemuAsterinasReference(kernel:, initramfs:, disk:, memory_mib:, network: if tap == "" { qemu.NoNetwork } else { qemu.Tap(tap) })
  qemu.qemu_run_asterinas_reference(config, input, console, qemu_log, timeout_seconds)
  let output = qemu.qemu_log_text(console, qemu_log)?
  let missing = guest_protocol.guest_missing_success_markers(output)
  guard missing.is_empty() else { fail f"guest proof is missing: {missing.join(", ")}" }
  if selection != "" {
    for requested in selection.split(" ") {
      guard f"LAPUTA_ASTERINAS_XSH_TEST_START {requested}" in output else {
        fail f"guest did not start the requested XSH test selection: {requested}"
      }
    }
    guard "LAPUTA_ASTERINAS_XSH_TEST_OK" in output else {
      fail "guest did not complete the requested XSH test selection"
    }
    guard "running " in output and !("running 0 tests" in output) and "test result: ok." in output else {
      fail "guest did not report a nonempty passing XSH test selection"
    }
  }
}
