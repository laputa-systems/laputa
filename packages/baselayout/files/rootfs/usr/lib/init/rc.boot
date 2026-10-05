#!/bin/xsh
for dir in [/proc, /sys, /run, /dev] {
  dir.mkdir()
}

let mount_proc = linux.mount("proc", /proc, fstype: "proc", options: ["nosuid", "noexec", "nodev"])
let mount_sys = linux.mount("sys", /sys, fstype: "sysfs", options: ["nosuid", "noexec", "nodev"])
let mount_run = linux.mount("run", /run, fstype: "tmpfs", options: ["mode=0755", "nosuid", "nodev"])
let mount_dev = linux.mount("dev", /dev, fstype: "devtmpfs", options: ["mode=0755", "nosuid"])

for dir in [/dev/pts, /dev/shm] {
  dir.mkdir()
}

let proc_filesystems = p"/proc/filesystems".read_text()?

if "devpts" in proc_filesystems {
  let _ = linux.mount(
    "devpts",
    /dev/pts,
    fstype: "devpts",
    options: ["mode=0620", "gid=5", "ptmxmode=0666", "nosuid", "noexec"],
  )

  if p"/dev/pts/ptmx".exists() and ! p"/dev/ptmx".exists() {
    match p"/dev/ptmx".symlink(to: p"pts/ptmx") {
      Ok(_) | Err(_) => {}
    }
  }
}

if ! p"/dev/ptmx".exists() {
  let _ = linux.mknod(/dev/ptmx, "char", 5, 2)
}

let mount_shm = linux.mount("shm", /dev/shm, fstype: "tmpfs", options: ["mode=1777", "nosuid", "nodev"])

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

if p"/usr/bin/mdev".exists() {
  run /usr/bin/mdev -s
}

let mount_all_result = linux.mount_all()
let swapon_all_result = linux.swapon_all()

if p"/proc/sys/net/ipv4/conf/lo".exists() {
  let _ = linux.link_up("lo")
}

if p"/etc/xsh-boot-epoch-ms".exists() {
  if let Ok(epoch_ms) = p"/etc/xsh-boot-epoch-ms".read_text()?.trim().parse_int() {
    let _ = linux.set_system_clock(epoch_ms)
  }
} else {
  if let Ok(epoch_ms) = linux.hwclock() {
    let _ = linux.set_system_clock(epoch_ms)
  }
}

if p"/etc/hostname".exists() {
  let hostname = p"/etc/hostname".read_text()?.trim()
  let _ = unix.set_hostname(hostname)
}

let sysctl_result = linux.sysctl_load_dirs(
  [/run/sysctl.d, /etc/sysctl.d, /usr/lib/sysctl.d],
  fallback: /etc/sysctl.conf,
)

for hook in g"/usr/lib/init/rc.d/*.boot" {
  if hook.is_file() {
    run $hook
  }
}

for hook in g"/etc/rc.d/*.boot" {
  if hook.is_file() {
    run $hook
  }
}
