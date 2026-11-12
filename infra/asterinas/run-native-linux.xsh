#!/bin/xsh --
use system.qemu

cli main(kernel: Path, initramfs: Path, disk: Path, console: Path, qemu_log: Path, timeout_seconds: Int) [fs, process, env, time, error] {
  let target = qemu.host_qemu_target()?
  let config = qemu.qemu_config(target)?
  let input = qemu.QemuAsterinasReference(kernel:, initramfs:, disk:, memory_mib: 4096, data_disk: qemu.NoDataDisk, network: qemu.NoNetwork, control: qemu.NoControl)
  qemu.qemu_run_asterinas_reference(config, input, console, qemu_log, timeout_seconds, qemu.guest_poweroff_timeout_seconds, proof: qemu.NativeXsh)
  let output = qemu.qemu_log_text(console, qemu_log)?
  guard "XSH_NATIVE_CONTEXT uid=1000 gid=1000 jobs=1" in output else { fail "native guest did not establish its unprivileged fixture" }
  guard "XSH_NATIVE_START " in output and "test result: ok." in output else { fail "native guest did not report passing native tests" }
}
