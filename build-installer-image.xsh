#!/bin/xsh
use installer.host as host
use installer.package_roots_host as package_roots_host
use system.image as system_image

error InstallerBuildError = Failed(message: Str)

proc run_xsh_tool(root: Path, xsh: Path, tool: Path, argv: List[Str]) [fs, process, env, error] {
  host.installer_run_argv(
    xsh,
    ["xsh", tool.display(), "--"].extend(argv),
    root,
    {XSH_MODULE_PATH: root.display(), XSH_UNIX_REAL: "1"},
  )?
}

proc ensure_dev_dirs(rootfs: Path) [fs, error] {
  for sub in ["dev", "dev/pts", "dev/shm", "proc", "run", "sys", "tmp"] {
    let dir = fp"{rootfs}/{sub}"

    if ! fs.exists(dir)? {
      fs.mkdir(dir)?
    }
  }
}

proc append_inittab_line(rootfs: Path, line: Str) [fs, error] {
  let inittab = fp"{rootfs}/etc/inittab"

  return unless fs.exists(inittab)?

  var text = fs.read_text(inittab)?

  return when line in text

  if ! text.ends_with("\n") {
    text = f"""{text}
"""
  }

  fs.write_atomic(
    inittab,
    f"""{text}{line}
""",
  )?
}

# The serial console QEMU's machine model provides: the PL011 UART on aarch64
# virt, the 16550 UART on x86_64 pc.
pure serial_console(arch: Str) -> Str {
  return "ttyS0" when arch == "x86_64"

  "ttyAMA0"
}

proc install_installer_tools(root: Path, rootfs: Path, arch: Str) [fs, env, error] {
  let installer_root = fp"{root}/installer"

  fs.install(
    fp"{installer_root}/setup-laputa.xsh",
    fp"{rootfs}/usr/bin/setup-laputa",
    0o755,
    parents: true,
    overwrite: true,
  )?

  fs.install(
    fp"{installer_root}/disk_selection.xsh",
    fp"{rootfs}/usr/bin/disk_selection.xsh",
    0o644,
    parents: true,
    overwrite: true,
  )?

  fs.install(
    fp"{installer_root}/laputa-network.boot",
    fp"{rootfs}/usr/lib/init/rc.d/laputa-network.boot",
    0o755,
    parents: true,
    overwrite: true,
  )?

  fs.install(
    fp"{installer_root}/laputa-ci-smoke.boot",
    fp"{rootfs}/usr/lib/init/rc.d/laputa-ci-smoke.boot",
    0o755,
    parents: true,
    overwrite: true,
  )?

  fs.install(
    fp"{installer_root}/setup-laputa-autoinstall.boot",
    fp"{rootfs}/usr/lib/init/rc.d/setup-laputa-autoinstall.boot",
    0o755,
    parents: true,
    overwrite: true,
  )?

  append_inittab_line(rootfs, f"{serial_console(arch)}::respawn:/bin/xshi")?
}

pure efi_boot_filename(arch: Str) -> Result[Str] {
  return "BOOTAA64.EFI" when arch == "aarch64"

  return "BOOTX64.EFI" when arch == "x86_64"

  Err(InstallerBuildError.Failed(f"unsupported installer EFI arch {arch}"))
}

# Image overlays change these roots after package composition, so a package
# generation receipt must not claim to describe the finished image.
proc drop_generation_receipt(rootfs: Path) [fs, error] {
  fs.remove(fp"{rootfs}/var/lib/laputa/generation.json", missing_ok: true)?
  fs.remove(fp"{rootfs}/var/lib/laputa/root.json", missing_ok: true)?
}

proc overlay_composed_roots(root: Path, roots: package_roots_host.InstallerRoots, arch: Str) [fs, env, error] {
  for rootfs in [roots.target, roots.installer, roots.tools] {
    drop_generation_receipt(rootfs)?
  }

  ensure_dev_dirs(roots.target)?
  install_installer_tools(root, roots.target, arch)?
  ensure_dev_dirs(roots.installer)?
  install_installer_tools(root, roots.installer, arch)?
}

proc prune_runtime_root(rootfs: Path, arch: Str) [fs, error] {
  fs.remove(fp"{rootfs}/boot/vmlinuz-7.2.9", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/include", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libc.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libclang_rt.builtins-{arch}.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libcrypt.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libdl.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libm.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libpthread.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/librt.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libssp_nonshared.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libutil.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libxnet.a", missing_ok: true)?
}

pure ceil_div(value: Int, divisor: Int) -> Int {
  (value + divisor - 1) / divisor
}

# laputa-fs's mkfs.ext4 layout: 4 KiB blocks in 32768-block groups, each of
# which reserves its first 516 blocks (headers and the inode table), and files
# mapped through indirect blocks of 1024 entries. Sizing from apparent bytes
# plus a fixed slack fails once a root spans more than a group or two.
const EXT4_BLOCK = 4096
const EXT4_GROUP_BLOCKS = 32768
const EXT4_GROUP_RESERVED = 516

# Data and mapping blocks for one tree: whole blocks per file plus one
# indirect block per 1024 data blocks and one for the double-indirect root,
# and for a directory, its entries at their 264-byte worst case.
proc tree_blocks(path_value: Path) [fs, error] -> Result[Int] {
  let meta = path_value.metadata()?

  if meta.kind != "dir" {
    let data = ceil_div(meta.size, EXT4_BLOCK)
    return data + ceil_div(data, 1024) + 1
  }

  let children = fs.children(path_value)?.collect()
  var total = 1 + ceil_div(children.len() * 264, EXT4_BLOCK)

  for child in children {
    total += if child.kind == "symlink" { 1 } else { tree_blocks(child.path)? }
  }

  total
}

proc installer_root_size_mb(rootfs: Path, override_mb: Str) [fs, error] -> Result[Int] {
  guard override_mb == "" else {
    return override_mb.parse_int()?
  }

  let data = tree_blocks(rootfs)?
  let groups = ceil_div(data, EXT4_GROUP_BLOCKS - EXT4_GROUP_RESERVED)
  ceil_div((data + groups * EXT4_GROUP_RESERVED) * EXT4_BLOCK, 1024 * 1024) + 1
}

proc write_iso_hybrid_gpt(image: Path, total_sectors: Int, root_start_lba: Int, root_end_lba: Int) [fs, error] {
  let entry_count = 8
  let entry_size = 128
  let entry_sectors = ceil_div(entry_count * entry_size, 512)
  let first_usable = 4
  let last_usable = total_sectors - entry_sectors - 2
  let primary_entries_lba = 2
  let backup_entries_lba = total_sectors - entry_sectors - 1

  let root_type = system_image.image_linux_partition_type_guid()?
  let disk_guid = bytes.zero(16)?

  let root_guid = bytes.from_ints(
    [
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
      85,
    ],
  )?

  let entries = bytes.concat(
    [
      system_image.image_gpt_entry(root_type, root_guid, root_start_lba, root_end_lba, "LAPUTA_INSTALLER_ROOT")?,
      bytes.zero(entry_count * entry_size - entry_size)?,
    ],
  )

  let entries_crc = hash.crc32(entries)

  let primary_header = system_image.image_gpt_header(
    1,
    total_sectors - 1,
    first_usable,
    last_usable,
    disk_guid,
    primary_entries_lba,
    entry_count,
    entry_size,
    entries_crc,
  )?

  let backup_header = system_image.image_gpt_header(
    total_sectors - 1,
    1,
    first_usable,
    last_usable,
    disk_guid,
    backup_entries_lba,
    entry_count,
    entry_size,
    entries_crc,
  )?

  let mbr_written = bytes.write_at(image, 0, system_image.protective_mbr(total_sectors)?)?
  let primary_entries_written = bytes.write_at(image, primary_entries_lba * 512, entries)?
  let primary_header_written = bytes.write_at(image, 512, primary_header)?
  let backup_entries_written = bytes.write_at(image, backup_entries_lba * 512, entries)?
  let backup_header_written = bytes.write_at(image, (total_sectors - 1) * 512, backup_header)?
  let _ = [mbr_written, primary_entries_written, primary_header_written, backup_entries_written, backup_header_written]
}

type IsoInput = {source: Path, name: Str}

type IsoFile = {source: Path, name: Str, extent: Int, size: Int}

pure sector_count(size: Int, sector_size: Int) -> Int {
  ceil_div(size, sector_size)
}

proc put_be(data: Bytes, offset: Int, value: Int, width: Int) [error] -> Result[Bytes] {
  var parts: List[Int] = []
  var index = width

  while index > 0 {
    index -= 1
    var divisor = 1
    var shift = index

    while shift > 0 {
      divisor *= 256
      shift -= 1
    }

    parts = parts.push(value / divisor % 256)
  }

  system_image.image_put_bytes(data, offset, bytes.from_ints(parts)?)?
}

proc put_both_16(data: Bytes, offset: Int, value: Int) [error] -> Result[Bytes] {
  var out = system_image.image_put_le(data, offset, value, 2)?
  out = put_be(out, offset + 2, value, 2)?
  out
}

proc put_both_32(data: Bytes, offset: Int, value: Int) [error] -> Result[Bytes] {
  var out = system_image.image_put_le(data, offset, value, 4)?
  out = put_be(out, offset + 4, value, 4)?
  out
}

proc fixed_ascii(text: Str, width: Int) [error] -> Result[Bytes] {
  let raw = bytes.from_text(text)

  return raw[..width] when raw.len() > width

  bytes.concat([raw, repeated_byte(32, width - raw.len())?])
}

proc repeated_byte(value: Int, count: Int) [error] -> Result[Bytes] {
  var values: List[Int] = []
  var remaining = count

  while remaining > 0 {
    values += [value]
    remaining -= 1
  }

  bytes.from_ints(values)?
}

proc iso_datetime_7() [error] -> Result[Bytes] {
  bytes.from_ints([126, 1, 1, 0, 0, 0, 0])?
}

proc iso_datetime_17() [error] -> Result[Bytes] {
  bytes.concat([bytes.from_text("2026010100000000"), bytes.from_ints([0])?])
}

proc iso_dir_record(extent: Int, size: Int, flags: Int, identifier: Bytes) [error] -> Result[Bytes] {
  let pad_len = if identifier.len() % 2 == 0 { 1 } else { 0 }
  let length = 33 + identifier.len() + pad_len
  var out = bytes.zero(length)?
  out = system_image.image_put_bytes(out, 0, bytes.from_ints([length, 0])?)?
  out = put_both_32(out, 2, extent)?
  out = put_both_32(out, 10, size)?
  out = system_image.image_put_bytes(out, 18, iso_datetime_7()?)?
  out = system_image.image_put_bytes(out, 25, bytes.from_ints([flags, 0, 0])?)?
  out = put_both_16(out, 28, 1)?
  out = system_image.image_put_bytes(out, 32, bytes.from_ints([identifier.len()])?)?
  out = system_image.image_put_bytes(out, 33, identifier)?
  out
}

proc iso_file_record(file: IsoFile) [error] -> Result[Bytes] {
  iso_dir_record(file.extent, file.size, 0, bytes.from_text(file.name))?
}

proc iso_root_record(root_extent: Int, root_size: Int, self_id: Int) [error] -> Result[Bytes] {
  iso_dir_record(root_extent, root_size, 2, bytes.from_ints([self_id])?)?
}

proc iso_root_dir(root_extent: Int, root_size: Int, files: List[IsoFile]) [error] -> Result[Bytes] {
  var records = [iso_root_record(root_extent, root_size, 0)?, iso_root_record(root_extent, root_size, 1)?]

  for file in files {
    records = records.push(iso_file_record(file)?)
  }

  let body = bytes.concat(records)
  bytes.concat([body, bytes.zero(root_size - body.len())?])
}

proc iso_path_table(root_extent: Int, big_endian: Bool) [error] -> Result[Bytes] {
  var out = bytes.zero(10)?
  out = system_image.image_put_bytes(out, 0, bytes.from_ints([1, 0])?)?

  if big_endian {
    out = put_be(out, 2, root_extent, 4)?
    out = put_be(out, 6, 1, 2)?
  } else {
    out = system_image.image_put_le(out, 2, root_extent, 4)?
    out = system_image.image_put_le(out, 6, 1, 2)?
  }

  out = system_image.image_put_bytes(out, 8, bytes.from_ints([0, 0])?)?
  out
}

proc iso_primary_descriptor(
  volume_id: Str,
  volume_sectors: Int,
  root_extent: Int,
  root_size: Int,
  path_table_size: Int,
  path_l: Int,
  path_m: Int,
) [error] -> Result[Bytes] {
  var out = bytes.zero(2048)?
  out = system_image.image_put_bytes(out, 0, bytes.from_ints([1])?)?
  out = system_image.image_put_bytes(out, 1, bytes.from_text("CD001"))?
  out = system_image.image_put_bytes(out, 6, bytes.from_ints([1, 0])?)?
  out = system_image.image_put_bytes(out, 8, fixed_ascii("LAPUTA", 32)?)?
  out = system_image.image_put_bytes(out, 40, fixed_ascii(volume_id, 32)?)?
  out = put_both_32(out, 80, volume_sectors)?
  out = put_both_16(out, 120, 1)?
  out = put_both_16(out, 124, 1)?
  out = put_both_16(out, 128, 2048)?
  out = put_both_32(out, 132, path_table_size)?
  out = system_image.image_put_le(out, 140, path_l, 4)?
  out = system_image.image_put_le(out, 144, 0, 4)?
  out = put_be(out, 148, path_m, 4)?
  out = put_be(out, 152, 0, 4)?
  out = system_image.image_put_bytes(out, 156, iso_root_record(root_extent, root_size, 0)?)?
  out = system_image.image_put_bytes(out, 190, fixed_ascii(volume_id, 128)?)?
  out = system_image.image_put_bytes(out, 318, fixed_ascii("LAPUTA SYSTEMS", 128)?)?
  out = system_image.image_put_bytes(out, 446, fixed_ascii("LAPUTA SYSTEMS", 128)?)?
  out = system_image.image_put_bytes(out, 574, fixed_ascii("XSH ISO9660 WRITER", 128)?)?
  out = system_image.image_put_bytes(out, 702, fixed_ascii("", 37)?)?
  out = system_image.image_put_bytes(out, 739, fixed_ascii("", 37)?)?
  out = system_image.image_put_bytes(out, 776, fixed_ascii("", 37)?)?
  out = system_image.image_put_bytes(out, 813, iso_datetime_17()?)?
  out = system_image.image_put_bytes(out, 830, iso_datetime_17()?)?
  out = system_image.image_put_bytes(out, 847, repeated_byte(48, 16)?)?
  out = system_image.image_put_bytes(out, 863, bytes.from_ints([0])?)?
  out = system_image.image_put_bytes(out, 864, repeated_byte(48, 16)?)?
  out = system_image.image_put_bytes(out, 880, bytes.from_ints([0, 1])?)?
  out
}

proc iso_terminator() [error] -> Result[Bytes] {
  var out = bytes.zero(2048)?
  out = system_image.image_put_bytes(out, 0, bytes.from_ints([255])?)?
  out = system_image.image_put_bytes(out, 1, bytes.from_text("CD001"))?
  out = system_image.image_put_bytes(out, 6, bytes.from_ints([1])?)?
  out
}

proc iso_files(inputs: List[IsoInput], first_extent: Int) [fs, error] -> Result[List[IsoFile]] {
  var extent = first_extent
  var files: List[IsoFile] = []

  for input in inputs {
    let size = input.source.metadata()?.size
    files = files.push({source: input.source, name: input.name, extent: extent, size: size})
    extent += sector_count(size, 2048)
  }

  files
}

proc write_iso9660(image: Path, volume_id: Str, inputs: List[IsoInput]) [fs, error] {
  let path_l = 18
  let path_m = 19
  let root_extent = 20
  let root_size = 2048
  let first_file_extent = 21
  let path_table_l = iso_path_table(root_extent, false)?
  let path_table_m = iso_path_table(root_extent, true)?
  let path_table_size = path_table_l.len()
  let files = iso_files(inputs, first_file_extent)?
  var volume_sectors = first_file_extent

  for file in files {
    volume_sectors = file.extent + sector_count(file.size, 2048)
  }

  fs.mkdir(image.parent())?
  fs.remove(image, missing_ok: true)?
  fs.write(image, "")?
  image.truncate(volume_sectors * 2048)?
  let lead_in = bytes.zero_at(image, 0, 16 * 2048)?

  let pvd = bytes.write_at(
    image,
    16 * 2048,
    iso_primary_descriptor(volume_id, volume_sectors, root_extent, root_size, path_table_size, path_l, path_m)?,
  )?

  let terminator = bytes.write_at(image, 17 * 2048, iso_terminator()?)?

  let path_l_write = bytes.write_at(
    image,
    path_l * 2048,
    bytes.concat([path_table_l, bytes.zero(2048 - path_table_l.len())?]),
  )?

  let path_m_write = bytes.write_at(
    image,
    path_m * 2048,
    bytes.concat([path_table_m, bytes.zero(2048 - path_table_m.len())?]),
  )?

  let root_write = bytes.write_at(image, root_extent * 2048, iso_root_dir(root_extent, root_size, files)?)?

  let _ = {
    lead_in,
    pvd,
    terminator,
    path_l_write,
    path_m_write,
    root_write,
  }

  for file in files {
    let copied = bytes.copy_file(
      file.source,
      image,
      source_offset: 0,
      dest_offset: file.extent * 2048,
      length: file.size,
      create: false,
      truncate: false,
    )?

    let _ = copied
  }
}

proc build_installer_iso(work: Path, iso: Path, kernel: Path, arch: Str) [fs, error] {
  let iso_arch = if arch == "aarch64" { "AARCH64" } else { "X86_64" }
  let installer_root = fp"{work}/installer-root.ext4"
  write_iso9660(iso, f"LAPUTA_{iso_arch}", [{source: kernel, name: "KERNEL;1"}])?
  let base_size = iso.metadata()?.size
  let root_size = installer_root.metadata()?.size
  let root_start_lba = ceil_div(base_size, 1024 * 1024) * 2048
  let root_sectors = ceil_div(root_size, 512)
  let root_end_lba = root_start_lba + root_sectors - 1
  let total_sectors = root_end_lba + 4
  iso.truncate(total_sectors * 512)?

  let copied = bytes.copy_file(
    installer_root,
    iso,
    source_offset: 0,
    dest_offset: root_start_lba * 512,
    length: root_size,
    create: false,
    truncate: false,
  )?

  let _ = copied
  write_iso_hybrid_gpt(iso, total_sectors, root_start_lba, root_end_lba)?
}

proc build_filesystems(
  root: Path,
  work: Path,
  xsh: Path,
  arch: Str,
  target_esp_mb: Str,
  boot_kernel: Path,
  installer_root_mb_override: Str,
  installer_ci: Str,
) [fs, process, env, error] {
  let efi_boot = efi_boot_filename(arch)?
  fs.mkdir(fp"{work}/rootfs-installer/usr/share/laputa-installer")?
  fs.mkdir(fp"{work}/rootfs-installer/usr/share/laputa-installer/esp/EFI/BOOT")?
  fs.mkdir(fp"{work}/rootfs-installer/etc/laputa-installer")?
  fs.write(fp"{work}/rootfs-installer/etc/laputa-installer/target-esp-mb", target_esp_mb)?

  fs.copy(
    boot_kernel,
    fp"{work}/rootfs-installer/usr/share/laputa-installer/esp/EFI/BOOT/{efi_boot}",
    overwrite: true,
  )?

  archive.tar_create(
    fp"{work}/target-root.tar.gz",
    fp"{work}/rootfs-target",
    [p"."],
    compression: "gz",
    overwrite: true,
  )?

  fs.copy(
    fp"{work}/target-root.tar.gz",
    fp"{work}/rootfs-installer/usr/share/laputa-installer/target-root.tar.gz",
    overwrite: true,
  )?

  if installer_ci == "1" {
    fs.write(fp"{work}/rootfs-installer/etc/laputa-installer/ci", "")?
  } else {
    fs.remove(fp"{work}/rootfs-installer/etc/laputa-installer/ci", missing_ok: true)?
  }

  let installer_root = fp"{work}/installer-root.ext4"
  let installer_root_mb = installer_root_size_mb(fp"{work}/rootfs-installer", installer_root_mb_override)?
  fs.write(installer_root, "")?
  installer_root.truncate(installer_root_mb * 1024 * 1024)?

  run_xsh_tool(
    root,
    xsh,
    fp"{work}/rootfs-tools/usr/bin/mkfs.ext4",
    [
      "-q",
      "-O",
      "^64bit,^metadata_csum",
      "-E",
      "no_copy_xattrs",
      "-L",
      "LAPUTA_ROOT",
      "-d",
      fp"{work}/rootfs-installer".display(),
      installer_root.display(),
    ],
  )?
}

proc build_host() [fs, net, process, env, time, error, io] {
  let root = host.installer_env_path("LAPUTA_ROOT", fs.cwd()?)?
  let arch = host.installer_arch(host.installer_env_value("LAPUTA_INSTALLER_ARCH", "aarch64"))?
  let work = host.installer_env_path("LAPUTA_INSTALLER_WORK", fp"{root}/target/laputa-installer-{arch}")?
  let iso = host.installer_env_path("LAPUTA_INSTALLER_ISO", fp"{work}/laputa-installer-{arch}.iso")?
  let kernel = host.installer_env_path("LAPUTA_INSTALLER_KERNEL", fp"{work}/laputa-installer-{arch}.vmlinuz")?
  let kernel_source_raw = host.installer_env_value("LAPUTA_INSTALLER_KERNEL_SOURCE", "")
  let repo_url = host.installer_env_value("LAPUTA_REPO_URL", "http://127.0.0.1:3000")
  let linux_package_name = host.installer_env_value("LAPUTA_INSTALLER_KERNEL_PACKAGE", "linux")
  let xsh = host.installer_env_path("XSH_HOST", process.which("xsh")?)?
  let qemu_smoke = host.installer_env_value("LAPUTA_INSTALLER_QEMU_SMOKE", "0")
  let qemu_authorized_key = host.installer_env_value("LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY", "")
  let target_esp_mb = host.installer_env_value("LAPUTA_TARGET_ESP_MB", "16")
  let installer_root_mb = host.installer_env_value("LAPUTA_INSTALLER_ROOT_MB", "")
  let installer_ci = host.installer_env_value("LAPUTA_INSTALLER_CI", "1")

  let roots = package_roots_host.InstallerRoots(
    target: fp"{work}/rootfs-target",
    installer: fp"{work}/rootfs-installer",
    tools: fp"{work}/rootfs-tools",
  )
  fs.mkdir(work)?

  for path_value in [
    fp"{work}/packages",
    roots.target,
    roots.installer,
    roots.tools,
    fp"{work}/esp",
    fp"{work}/laputa-installer-{arch}.img",
    fp"{work}/laputa-installer-manual-{arch}.img",
    fp"{work}/target-root.tar.gz",
    fp"{work}/target-root.ext4",
    fp"{work}/target-esp.vfat",
    fp"{work}/linux-kernel",
  ] {
    host.installer_remove_tree(path_value)?
  }

  package_roots_host.prepare(
    root,
    arch,
    repo_url,
    linux_package_name,
    qemu_smoke == "1",
    host.installer_env_value("LAPUTA_INSTALLER_JOBS", "4").parse_int()?,
    fp"{work}/packages",
    roots,
  )?
  overlay_composed_roots(root, roots, arch)?

  if qemu_smoke == "1" {
    if qemu_authorized_key == "" {
      return Err(
        InstallerBuildError.Failed("LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY is required when smoke mode is enabled"),
      )
    }

    let key_path = fp"{qemu_authorized_key}"

    if ! fs.exists(key_path)? {
      return Err(InstallerBuildError.Failed(f"missing {key_path}"))
    }

    fs.mkdir(fp"{work}/rootfs-target/etc/laputa-installer")?
    fs.copy(key_path, fp"{work}/rootfs-target/etc/laputa-installer/qemu-smoke-authorized-key.pub", overwrite: true)?
  }

  prune_runtime_root(roots.target, arch)?
  prune_runtime_root(roots.installer, arch)?
  let packaged_kernel = fp"{work}/rootfs-target/boot/vmlinuz"
  let boot_kernel = if kernel_source_raw == "" { packaged_kernel } else { fp"{kernel_source_raw}" }

  if ! fs.exists(boot_kernel)? {
    return Err(InstallerBuildError.Failed(f"missing installer kernel source {boot_kernel}"))
  }

  fs.copy(boot_kernel, kernel, overwrite: true)?
  build_filesystems(root, work, xsh, arch, target_esp_mb, boot_kernel, installer_root_mb, installer_ci)?
  build_installer_iso(work, iso, kernel, arch)?

  io.write_stdout(f"""{iso}
""")?
}

proc main(...argv: List[Str]) [fs, net, process, env, time, error, io] {
  if argv.len() > 0 {
    return Err(InstallerBuildError.Failed("build-installer-image.xsh does not accept subcommands"))
  }

  build_host()?
}

main(@args)?
