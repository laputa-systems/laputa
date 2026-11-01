#!/bin/xsh --
use infra.asterinas.guest_protocol
use system.qemu

cli main(kernel: Path, initramfs: Path, disk: Path, console: Path, qemu_log: Path, selection: Str, timeout_seconds: Int) [fs, process, env, time, error] {
  let target = qemu.host_qemu_target()?
  let config = qemu.qemu_config(target)?
  let memory_mib = if selection == "" { 1024 } else { 4096 }
  let input = qemu.QemuAsterinasReference(kernel:, initramfs:, disk:, memory_mib:)
  qemu.qemu_run_asterinas_reference(config, input, console, qemu_log, timeout_seconds)
  let output = qemu.qemu_log_text(console, qemu_log)?
  let missing = guest_protocol.guest_missing_success_markers(output)
  guard missing.is_empty() else { fail f"guest proof is missing: {missing.join(", ")}" }
  if selection != "" {
    guard f"LAPUTA_ASTERINAS_XSH_TEST_START {selection}" in output and "LAPUTA_ASTERINAS_XSH_TEST_OK" in output else {
      fail "guest did not complete the requested XSH test selection"
    }
    guard "running " in output and !("running 0 tests" in output) and "test result: ok." in output else {
      fail "guest did not report a nonempty passing XSH test selection"
    }
  }
}
