#!/bin/xsh --
error AsterinasBootSetupError = Failed(phase: Str, message: Str)

proc require(condition: Bool, phase: Str, message: Str) {
  guard condition else {
    eprint --flush f"LAPUTA_ASTERINAS_TEST_FAILED {phase}: {message}"
    return Err(AsterinasBootSetupError.Failed(phase:, message:))
  }
}

proc main() [fs, process, error] {
  eprint --flush "LAPUTA_ASTERINAS_BOOT_SETUP_START"
  require(linux.is_mountpoint(/proc)?, "proc", "initramfs proc mount was not moved into the root")
  require(linux.is_mountpoint(/sys)?, "sysfs", "initramfs sysfs mount was not moved into the root")
  require(linux.is_mountpoint(/dev)?, "dev", "initramfs devtmpfs mount was not moved into the root")
  require(p"/proc/1/cmdline".exists()?, "proc", "PID 1 command line is unavailable")

  for dir in [/dev/pts, /dev/shm, /run, /tmp] {
    dir.mkdir()
  }

  linux.mount(bytes.from_text("run"), /run, fstype: "tmpfs", options: ["mode=0755", "nosuid", "nodev"])
  linux.mount(bytes.from_text("devpts"), /dev/pts, fstype: "devpts", options: ["mode=0620", "gid=5", "ptmxmode=0666", "nosuid", "noexec"])
  linux.mount(bytes.from_text("shm"), /dev/shm, fstype: "tmpfs", options: ["mode=1777", "nosuid", "nodev"])
  linux.mount_all()

  if p"/dev/pts/ptmx".exists() and ! p"/dev/ptmx".exists() {
    p"/dev/ptmx".symlink(to: p"pts/ptmx")
  }
  if ! p"/dev/fd".exists() {
    p"/dev/fd".symlink(to: /proc/self/fd)
  }
  if ! p"/dev/stdin".exists() {
    p"/dev/stdin".symlink(to: p"fd/0")
  }
  if ! p"/dev/stdout".exists() {
    p"/dev/stdout".symlink(to: p"fd/1")
  }
  if ! p"/dev/stderr".exists() {
    p"/dev/stderr".symlink(to: p"fd/2")
  }

  # Asterinas does not publish the per-device uevent file that Laputa's Linux
  # mdev scan requires, so this profile prepares the mounted filesystems directly.
  eprint --flush "LAPUTA_ASTERINAS_BOOT_SETUP_OK"
}

main()
