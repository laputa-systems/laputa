#!/bin/xsh
error InstallerError = Failed(kind: Str, message: Str)

let ESP_TYPE = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
let SWAP_TYPE = "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
let LINUX_TYPE = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
let TARGET_ROOT_PARTUUID = "33333333-3333-3333-3333-333333333333"

pure ceil_div(value: Int, divisor: Int) -> Int {
  return (value + divisor - 1) / divisor
}

pure align_up(value: Int, alignment: Int) -> Int {
  return ceil_div(value, alignment) * alignment
}

pure align_down(value: Int, alignment: Int) -> Int {
  return value / alignment * alignment
}

pure is_disk_name(name: Str) -> Bool {
  return ! name.starts_with("loop") and ! name.starts_with("ram") and ! name.starts_with("dm-")
}

pure partition_path(disk: Path, index: Int) -> Path {
  let name = disk.name

  if name.starts_with("nvme") or name.starts_with("mmcblk") {
    return fp"${disk.display()}p${index}"
  }

  return fp"${disk.display()}${index}"
}

pure prefix_octet(bits: Int) -> Int {
  if bits <= 0 {
    return 0
  } else if bits >= 8 {
    return 255
  } else if bits == 7 {
    return 254
  } else if bits == 6 {
    return 252
  } else if bits == 5 {
    return 248
  } else if bits == 4 {
    return 240
  } else if bits == 3 {
    return 224
  } else if bits == 2 {
    return 192
  } else {
    return 128
  }
}

pure prefix_to_netmask(prefix_len: Int) -> Str {
  return f"${prefix_octet(prefix_len)}.${prefix_octet(prefix_len - 8)}.${prefix_octet(prefix_len - 16)}.${prefix_octet(
    prefix_len - 24,
  )}"
}

proc write_text(text: Str) [fs, error, io] {
  if fs.exists(/dev/ttyAMA0)? {
    fs.write(/dev/ttyAMA0, text)?
  } else {
    io.write_stdout(text)?
  }
}

proc write_stdout_line(line: Str) [fs, error, io] {
  write_text(f"""${line}
""")?
}

proc usage() [fs, error, io] {
  write_stdout_line("usage: setup-laputa [--auto] [--ci] [--disk DEV]")?
}

proc require_file(path_value: Path) [fs, error] {
  if ! fs.exists(path_value)? {
    return Err(InstallerError.Failed("missing-file", path_value.display()))
  }
}

proc run_argv(target: Path, argv: List[Str]) [fs, process, error] {
  let status = process.run(process.command_argv(target, argv, /, {}))?

  if status.ok {
    return
  }

  if status.exited() {
    abort(status.exit_code()?)
  }

  return Err(InstallerError.Failed("command-signaled", argv[0]))
}

proc write_file(path_value: Path, body: Str) [fs, error] {
  path_value.parent.mkdir()?
  fs.write(path_value, body)?
}

proc normalize_target_ownership(root: Path) [fs, error] {
  let root_user = user.by_uid(0)?
  let root_group = group.by_gid(0)?
  fs.chown(root, root_user)?
  fs.chgrp(root, root_group)?

  for entry in fs.walk(root, gitignore: false)? {
    if entry.kind != "symlink" {
      fs.chown(entry.path, root_user)?
      fs.chgrp(entry.path, root_group)?
    }
  }

  for path_value in [
    fp"${root}/usr/bin/passwd",
    fp"${root}/usr/bin/su",
    fp"${root}/usr/bin/sudo",
    fp"${root}/usr/bin/unix_chkpwd",
  ] {
    if fs.exists(path_value)? {
      fs.chmod(path_value, 0o4755)?
    }
  }
}

proc configure_qemu_smoke_ssh(root: Path) [fs, error] -> Result[Bool] {
  let public_key_path = fp"${root}/etc/laputa-installer/qemu-smoke-authorized-key.pub"

  if ! fs.exists(public_key_path)? {
    return false
  }

  let public_key = fs.read_text(public_key_path)?.trim()

  if public_key == "" {
    return false
  }

  let ssh_dir = fp"${root}/home/pazu/.ssh"
  let authorized_keys = fp"${ssh_dir}/authorized_keys"
  fs.mkdir(fp"${root}/etc/dropbear")?
  fs.mkdir(ssh_dir)?

  fs.write(
    authorized_keys,
    f"""${public_key}
""",
  )?

  fs.chown(fp"${root}/home/pazu", user.by_uid(1000)?)?
  fs.chgrp(fp"${root}/home/pazu", group.by_gid(1000)?)?
  fs.chown(ssh_dir, user.by_uid(1000)?)?
  fs.chgrp(ssh_dir, group.by_gid(1000)?)?
  fs.chown(authorized_keys, user.by_uid(1000)?)?
  fs.chgrp(authorized_keys, group.by_gid(1000)?)?
  fs.chmod(ssh_dir, 0o700)?
  fs.chmod(authorized_keys, 0o600)?
  return true
}

proc list_disks() [process, error] -> Result[List[Path]] {
  var blank: List[Path] = []
  var partitioned: List[Path] = []
  let devices = linux.block_devices()?

  for device in devices {
    if is_disk_name(device.name) {
      if device.partitioned {
        partitioned = partitioned.push(device.path)
      } else {
        blank = blank.push(device.path)
      }
    }
  }

  return blank.extend(partitioned)
}

proc print_disks(disks: List[Path]) [fs, error, io] {
  write_stdout_line("Available disks:")?

  for disk in disks {
    write_stdout_line(f"  ${disk.display()}")?
  }
}

proc disk_has_partitions(disk: Path) [fs, error] -> Result[Bool] {
  for entry in fs.ls(fp"/sys/block/${disk.name}")? {
    if entry.name.starts_with(disk.name) and fs.exists(fp"/sys/block/${disk.name}/${entry.name}/partition")? {
      return true
    }
  }

  return false
}

proc ci_default_disk(disks: List[Path]) [fs, error] -> Result[Path] {
  for disk in disks {
    if ! disk_has_partitions(disk)? {
      return disk
    }
  }

  return Err(InstallerError.Failed("no-blank-disk", "no blank CI install disk found"))
}

proc ci_target_installed(disks: List[Path]) [fs, error] -> Result[Bool] {
  for disk in disks {
    for entry in fs.ls(fp"/sys/block/${disk.name}")? {
      let partition_marker = fp"/sys/block/${disk.name}/${entry.name}/partition"
      let uevent = fp"/sys/block/${disk.name}/${entry.name}/uevent"

      if fs.exists(partition_marker)? and fs.exists(uevent)? {
        if f"PARTUUID=${TARGET_ROOT_PARTUUID}" in fs.read_text(uevent)? {
          return true
        }
      }
    }
  }

  return false
}

proc prompt_disk(default_disk: Path) [fs, process, error, io] -> Result[Path] {
  write_text(f"Install to disk [${default_disk.display()}]: ")?
  let answer = io.stdin_line()?
  let trimmed = answer.trim()

  if trimmed == "" {
    return default_disk
  }

  return fp"${trimmed}"
}

proc wait_for(path_value: Path) [fs, time, error] {
  var tries = 50

  while tries > 0 {
    if fs.exists(path_value)? {
      return
    }

    time.sleep(100ms)?
    tries -= 1
  }

  return Err(InstallerError.Failed("device-timeout", path_value.display()))
}

proc installer_network_interfaces() [process, error] -> Result[Record] {
  let interfaces = linux.interfaces()?
  let routes = linux.routes()?
  var iface = ""
  var address = ""
  var netmask = "255.255.255.0"
  var gateway = "10.0.2.2"

  for item in interfaces {
    if item.name != "lo" and address == "" {
      for addr in item.addresses {
        if addr.family == "inet" and address == "" {
          iface = item.name
          address = addr.addr
          netmask = prefix_to_netmask(addr.prefix_len)
        }
      }
    }
  }

  for route in routes {
    if route.dst == "default" and route.gateway != "" and "." in route.gateway {
      gateway = route.gateway
    }
  }

  if iface == "" {
    iface = "eth0"
  }

  if address == "" {
    address = "10.0.2.15"
  }

  return {iface, address, netmask, gateway}
}

proc target_static_interfaces() [process, error] -> Result[Str] {
  let netcfg = installer_network_interfaces()?

  return f"""auto lo
iface lo inet loopback

auto ${netcfg.iface}
iface ${netcfg.iface} inet static
    address ${netcfg.address}
    netmask ${netcfg.netmask}
    gateway ${netcfg.gateway}
"""
}

proc target_dhcp_interfaces() [process, error] -> Result[Str] {
  let netcfg = installer_network_interfaces()?

  return f"""auto lo
iface lo inet loopback

auto ${netcfg.iface}
iface ${netcfg.iface} inet dhcp
"""
}

proc target_interfaces(network_method: Str) [process, error] -> Result[Str] {
  if network_method == "static" {
    return target_static_interfaces()?
  }

  return target_dhcp_interfaces()?
}

# Like Alpine setup, ask whether the target should use DHCP or a static address
# and write that choice explicitly. Non-interactive (--ci) installs keep the
# deterministic static configuration derived from the live network.
proc prompt_network_method(ci: Bool) [fs, error, io] -> Result[Str] {
  if ci {
    return "static"
  }

  write_text("Network configuration - [d]hcp or [s]tatic? [dhcp]: ")?
  let answer = io.stdin_line()?.trim().lower()

  if answer == "s" or answer == "static" {
    return "static"
  }

  return "dhcp"
}

proc write_target_config(
  root: Path,
  esp_part: Path,
  swap_part: Path,
  root_part: Path,
  ci: Bool,
  network_method: Str,
) [fs, process, error] {
  # laputa-net provides /usr/bin/ifup as a symlink into xsh core.
  # The target rootfs already has laputa-net installed, so the symlink
  # is already present after extraction. No need to copy anything.
  let fstab_root = if ci { "/dev/vda3" } else { root_part.display() }
  let fstab_esp = if ci { "/dev/vda1" } else { esp_part.display() }
  let fstab_swap = if ci { "/dev/vda2" } else { swap_part.display() }

  write_file(
    fp"${root}/etc/hostname",
    """laputa
""",
  )?

  write_file(
    fp"${root}/etc/fstab",
    f"""proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devtmpfs /dev devtmpfs defaults 0 0
tmpfs /run tmpfs mode=0755,nosuid,nodev 0 0
tmpfs /dev/shm tmpfs mode=1777,nosuid,nodev 0 0
${fstab_root} / ext4 rw,noatime 0 1
${fstab_esp} /boot vfat rw,noatime 0 2
${fstab_swap} none swap sw 0 0
""",
  )?

  write_file(
    fp"${root}/etc/passwd",
    """root:x:0:0:root:/root:/bin/xshi
pazu:x:1000:1000:Pazu:/home/pazu:/bin/xshi
nobody:x:99:99:Unprivileged User:/dev/null:/bin/false
""",
  )?

  write_file(
    fp"${root}/etc/shadow",
    """root:*:0:0:99999:7:::
pazu:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
""",
  )?

  write_file(
    fp"${root}/etc/group",
    """root:x:0:
wheel:x:4:pazu
tty:x:5:
disk:x:9:
dialout:x:11:
audio:x:12:
video:x:13:
network:x:21:
kvm:x:24:
input:x:25:
seat:x:26:
nogroup:x:99:
users:x:100:
pazu:x:1000:
""",
  )?

  write_file(fp"${root}/etc/network/interfaces", target_interfaces(network_method)?)?

  if ci {
    write_file(
      fp"${root}/usr/local/bin/laputa-ci-idle",
      """#!/bin/xsh
proc main() [time, error] {
while true {
  time.sleep(60s)?
}
}

main()?
""",
    )?

    fs.chmod(fp"${root}/usr/local/bin/laputa-ci-idle", 0o755)?
  } else {
    write_file(
      fp"${root}/etc/inittab",
      """::sysinit:/usr/lib/init/rc.boot
::once:/usr/lib/init/mdev.supervise
ttyAMA0::respawn:/usr/bin/login -f pazu
tty1::respawn:/usr/bin/login -f pazu
::restart:/usr/bin/xinit /etc/inittab
::shutdown:/usr/lib/init/rc.shutdown
""",
    )?
  }

  fp"${root}/home/pazu".mkdir()?
  fs.chmod(fp"${root}/home/pazu", 0o755)?
  let qemu_smoke_ssh = if ci { configure_qemu_smoke_ssh(root)? } else { false }

  if ci {
    let dropbear_line = if qemu_smoke_ssh {
      """::once:/usr/bin/xinit supervise dropbear
"""
    } else {
      ""
    }

    write_file(
      fp"${root}/etc/inittab",
      f"""::sysinit:/usr/lib/init/rc.boot
::once:/usr/lib/init/mdev.supervise
${dropbear_line}::respawn:/usr/local/bin/laputa-ci-idle
::shutdown:/usr/lib/init/rc.shutdown
""",
    )?

    # laputa-ci-smoke.boot is installed into the installer rootfs by
    # install_installer_tools. Copy it into the target rootfs.
    fs.install(
      /usr/lib/init/rc.d/laputa-ci-smoke.boot,
      fp"${root}/usr/lib/init/rc.d/laputa-ci-smoke.boot",
      0o755,
      parents: true,
      overwrite: true,
    )?
  }
}

proc configured_ci_esp_bytes() [fs, error] -> Result[Int] {
  let path_value = /etc/laputa-installer/target-esp-mb

  if ! fs.exists(path_value)? {
    return 16 * 1024 * 1024
  }

  let mb = fs.read_text(path_value)?.trim().parse_int()?
  return mb * 1024 * 1024
}

proc wipe_and_partition(disk: Path, ci: Bool) [fs, process, error] -> Result[Record] {
  let total_sectors = fs.read_text(fp"/sys/block/${disk.name}/size")?.trim().parse_int()?
  let esp_bytes = if ci { configured_ci_esp_bytes()? } else { 128 * 1024 * 1024 }
  let swap_bytes = if ci { 8 * 1024 * 1024 } else { linux.meminfo()?.total * 2 }
  let esp_sectors = align_up(ceil_div(esp_bytes, 512), 2048)
  let swap_sectors = align_up(ceil_div(swap_bytes, 512), 2048)
  let first = 2048
  let esp_start = first
  let esp_end = esp_start + esp_sectors - 1
  let swap_start = align_up(esp_end + 1, 2048)
  let swap_end = swap_start + swap_sectors - 1
  let root_start = align_up(swap_end + 1, 2048)
  let root_sectors = align_down(total_sectors - 2048 - root_start + 1, 8)
  let root_end = root_start + root_sectors - 1

  if root_sectors <= 0 or root_end <= root_start {
    return Err(InstallerError.Failed("disk-too-small", f"${disk.display()} is too small for Laputa"))
  }

  let table = json.decode(
    f"""{
  "label": "gpt",
  "uuid": "11111111-2222-3333-4444-555555555555",
  "partitions": [
    {"index": 1, "start": ${esp_start}, "end": ${esp_end}, "type": "${ESP_TYPE}", "uuid": "11111111-1111-1111-1111-111111111111", "name": "LAPUTA_ESP"},
    {"index": 2, "start": ${swap_start}, "end": ${swap_end}, "type": "${SWAP_TYPE}", "uuid": "22222222-2222-2222-2222-222222222222", "name": "LAPUTA_SWAP"},
    {"index": 3, "start": ${root_start}, "end": ${root_end}, "type": "${LINUX_TYPE}", "uuid": "33333333-3333-3333-3333-333333333333", "name": "LAPUTA_ROOT"}
  ]
}""",
  )?

  linux.write_partition_table(disk, table)?
  return {esp: partition_path(disk, 1), swap: partition_path(disk, 2), root: partition_path(disk, 3)}
}

proc install_to_disk(disk: Path, ci: Bool) [fs, process, time, error, io] {
  require_file(/usr/bin/mkfs.ext4)?
  require_file(/usr/bin/mkfs.vfat)?
  require_file(/usr/share/laputa-installer/target-root.tar.gz)?
  let network_method = prompt_network_method(ci)?
  write_stdout_line(f"Installing Laputa to ${disk.display()}")?
  let parts = wipe_and_partition(disk, ci)?
  wait_for(parts.esp)?
  wait_for(parts.swap)?
  wait_for(parts.root)?
  run_argv(/usr/bin/mkfs.vfat, ["mkfs.vfat", "-n", "LAPUTA_ESP", parts.esp.display()])?

  run_argv(
    /usr/bin/mkfs.ext4,
    [
      "mkfs.ext4",
      "-q",
      "-O",
      "^64bit,^metadata_csum",
      "-E",
      "no_copy_xattrs",
      "-L",
      "LAPUTA_ROOT",
      parts.root.display(),
    ],
  )?

  linux.mkswap(parts.swap)?
  fs.mkdir(/mnt/target)?
  linux.mount(parts.root.display(), /mnt/target, fstype: "ext4")?
  archive.tar_extract(/usr/share/laputa-installer/target-root.tar.gz, /mnt/target, 0, "auto", true)?
  normalize_target_ownership(/mnt/target)?
  fs.mkdir(/mnt/target/boot)?
  linux.mount(parts.esp.display(), /mnt/target/boot, fstype: "vfat")?

  if fs.exists(/usr/share/laputa-installer/esp/EFI/BOOT/BOOTAA64.EFI)? {
    fs.install(
      /usr/share/laputa-installer/esp/EFI/BOOT/BOOTAA64.EFI,
      /mnt/target/boot/EFI/BOOT/BOOTAA64.EFI,
      0o644,
      parents: true,
      overwrite: true,
    )?
  }

  if fs.exists(/usr/share/laputa-installer/esp/EFI/BOOT/BOOTX64.EFI)? {
    fs.install(
      /usr/share/laputa-installer/esp/EFI/BOOT/BOOTX64.EFI,
      /mnt/target/boot/EFI/BOOT/BOOTX64.EFI,
      0o644,
      parents: true,
      overwrite: true,
    )?
  }

  write_target_config(/mnt/target, parts.esp, parts.swap, parts.root, ci, network_method)?
  linux.umount_all(["vfat", "ext4"])?
  write_stdout_line("Laputa install complete. Remove installer media before booting the target disk.")?
}

proc main(...argv: List[Str]) [fs, process, time, error, io] {
  var ci = false
  var auto = false
  var disk_text = ""
  var index = 0

  while index < argv.len() {
    let arg = argv[index]

    if arg == "--help" {
      usage()
      return
    } else if arg == "--ci" {
      ci = true
      auto = true
    } else if arg == "--auto" {
      auto = true
    } else if arg == "--disk" {
      index += 1

      if index >= argv.len() {
        return Err(InstallerError.Failed("usage", "--disk requires a device"))
      }

      disk_text = argv[index]
    } else {
      return Err(InstallerError.Failed("usage", f"unknown argument ${arg}"))
    }

    index += 1
  }

  let disks = list_disks()?

  if disks.len() == 0 {
    return Err(InstallerError.Failed("no-disks", "no installable disks found"))
  }

  print_disks(disks)?

  if ci and disk_text == "" and ci_target_installed(disks)? {
    write_stdout_line("Laputa CI target already installed.")?
    return
  }

  let disk = if disk_text != "" {
    fp"${disk_text}"
  } else if ci {
    ci_default_disk(disks)?
  } else if auto {
    disks[0]
  } else {
    prompt_disk(disks[0])?
  }

  install_to_disk(disk, ci)?
}

env XSH_LINUX_REAL="1" {
  main(@args)?
} ?
