#!/bin/xsh
for dir in [/proc, /sys, /run, /dev, /dev/pts, /dev/shm] {
  if ! dir.exists() {
    dir.mkdir()
  }
}

let mount_proc = linux.mount("proc", /proc, fstype: "proc", options: ["nosuid", "noexec", "nodev"])
let mount_sys = linux.mount("sys", /sys, fstype: "sysfs", options: ["nosuid", "noexec", "nodev"])
let mount_run = linux.mount("run", /run, fstype: "tmpfs", options: ["mode=0755", "nosuid", "nodev"])
let mount_dev = linux.mount("dev", /dev, fstype: "devtmpfs", options: ["mode=0755", "nosuid"])

if "devpts" in p"/proc/filesystems".read_text()? {
  match linux.mount("devpts", /dev/pts, fstype: "devpts", options: ["mode=0620", "gid=5", "nosuid", "noexec"]) {
    Ok(_) | Err(_) => {}
  }
}

let mount_shm = linux.mount("shm", /dev/shm, fstype: "tmpfs", options: ["mode=1777", "nosuid", "nodev"])

if p"/etc/hostname".exists() {
  let hostname = p"/etc/hostname".read_text()?.trim()

  match unix.set_hostname(hostname) {
    Ok(_) | Err(_) => {}
  }
}

for hook in g"/usr/lib/init/rc.d/*.boot" {
  if hook.is_file() {
    run hook
  }
}

for hook in g"/etc/rc.d/*.boot" {
  if hook.is_file() {
    run hook
  }
}
