#!/bin/xsh
use installer.package_roots_host as package_roots_host

error InstallerBuildError = Failed(message: Str)

proc installer_env_value(name: Str, fallback: Str) [env] -> Str {
  let value = env.get(name) ?? ""

  return fallback when value == ""

  value
}

proc env_path(name: Str, fallback: Path) [env, error] -> Result[Path] {
  fp"{installer_env_value(name, fallback.display())}"
}

proc installer_work_path(root: Path, arch: Str) [env, error] -> Result[Path] {
  let raw = env.get("LAPUTA_INSTALLER_WORK") ?? ""

  return fp"{raw}" when raw.trim() != ""

  fp"{root}/target/laputa-installer-{arch}"
}

proc run_argv(target: Path, argv: List[Str], cwd: Path, envs: Record = {}) [process, error] {
  let status = process.run(process.command_argv(target, argv, cwd, envs))?

  return when status.ok

  if status.exited() {
    abort(status.exit_code()?)
  }

  return Err(InstallerBuildError.Failed(f"{argv[0]} was signaled"))
}

proc run_xsh_tool(root: Path, xsh: Path, tool: Path, argv: List[Str]) [fs, process, env, error] {
  run_argv(
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

proc install_installer_tools(root: Path, rootfs: Path) [fs, env, error] {
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

  append_inittab_line(rootfs, "ttyAMA0::respawn:/bin/xshi")?
}

# Only aarch64 installers build from the local package graph today; other
# architectures fail here instead of reaching an arch-specific path.
pure normalize_installer_arch(arch: Str) -> Result[Str] {
  return "aarch64" when arch == "arm64" or arch == "aarch64"

  Err(InstallerBuildError.Failed(f"unsupported installer arch {arch}"))
}

pure efi_boot_filename(arch: Str) -> Result[Str] {
  return "BOOTAA64.EFI" when arch == "aarch64"

  return "BOOTX64.EFI" when arch == "x86_64"

  Err(InstallerBuildError.Failed(f"unsupported installer EFI arch {arch}"))
}

proc remove_tree(path_value: Path) [fs, error] {
  guard fs.exists(path_value)? else {
    return
  }

  let meta = path_value.metadata()?

  if meta.kind != "dir" {
    path_value.remove()?
    return
  }

  for child in fs.children(path_value)? {
    if child.kind == "dir" {
      remove_tree(child.path)?
    } else {
      child.path.remove()?
    }
  }

  path_value.remove_dir()?
}

proc install_composed_root(bundle: Path, label: Str, output: Path) [fs, error] {
  archive.tar_extract(fp"{bundle}/{label}-root.tar.gz", output, 0, "auto", true)?

  # Image overlays change these roots after package composition, so a package
  # generation receipt must not claim to describe the finished image.
  fs.remove(fp"{output}/var/lib/laputa/generation.json", missing_ok: true)?
  fs.remove(fp"{output}/var/lib/laputa/root.json", missing_ok: true)?
}

proc assemble_composed_roots(root: Path, work: Path, bundle: Path) [fs, env, error] {
  let target = fp"{work}/rootfs-target"
  let installer = fp"{work}/rootfs-installer"
  install_composed_root(bundle, "target", target)?
  install_composed_root(bundle, "installer", installer)?
  install_composed_root(bundle, "tools", fp"{work}/rootfs-tools")?

  ensure_dev_dirs(target)?
  install_installer_tools(root, target)?
  ensure_dev_dirs(installer)?
  install_installer_tools(root, installer)?
}

proc prune_runtime_root(rootfs: Path) [fs, error] {
  fs.remove(fp"{rootfs}/boot/vmlinuz-7.0.5", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/include", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libc.a", missing_ok: true)?
  fs.remove(fp"{rootfs}/usr/lib/libclang_rt.builtins-aarch64.a", missing_ok: true)?
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

proc path_size(path_value: Path) [fs, error] -> Result[Int] {
  guard fs.exists(path_value)? else {
    return 0
  }

  let meta = path_value.metadata()?

  return meta.size when meta.kind != "dir"

  var total = meta.size

  for child in fs.children(path_value)? {
    total += path_size(child.path)?
  }

  total
}

proc installer_root_size_mb(rootfs: Path, override_mb: Str) [fs, error] -> Result[Int] {
  guard override_mb == "" else {
    return override_mb.parse_int()?
  }

  ceil_div(path_size(rootfs)?, 1024 * 1024) + 4
}

proc put(data: Bytes, offset: Int, replacement: Bytes) [error] -> Result[Bytes] {
  bytes.concat(
    [
      data[..offset],
      replacement,
      data[offset + replacement.len()..],
    ],
  )
}

proc put_le(data: Bytes, offset: Int, value: Int, width: Int) [error] -> Result[Bytes] {
  put(data, offset, bytes.pack_le(value, width)?)?
}

proc gpt_name(name: Str) [error] -> Result[Bytes] {
  let raw = bytes.from_text(name)
  var parts = [bytes.zero(0)?]
  var index = 0

  while index < raw.len() and index < 36 {
    parts = parts.push(bytes.from_ints([bytes.unpack_le(raw, 1, offset: index)?, 0])?)
    index += 1
  }

  let encoded = bytes.concat(parts)
  bytes.concat([encoded, bytes.zero(72 - encoded.len())?])
}

proc gpt_entry(type_guid: Bytes, part_guid: Bytes, start_lba: Int, end_lba: Int, name: Str) [error] -> Result[Bytes] {
  var entry = bytes.zero(128)?
  entry = put(entry, 0, type_guid)?
  entry = put(entry, 16, part_guid)?
  entry = put_le(entry, 32, start_lba, 8)?
  entry = put_le(entry, 40, end_lba, 8)?
  entry = put(entry, 56, gpt_name(name)?)?
  entry
}

proc protective_mbr(total_sectors: Int) [error] -> Result[Bytes] {
  var sector = bytes.zero(512)?
  sector = put(sector, 447, bytes.from_ints([0, 2, 0])?)?
  sector = put(sector, 450, bytes.from_ints([238])?)?
  sector = put(sector, 451, bytes.from_ints([255, 255, 255])?)?
  sector = put_le(sector, 454, 1, 4)?
  sector = put_le(sector, 458, total_sectors - 1, 4)?
  sector = put(sector, 510, bytes.from_ints([85, 170])?)?
  sector
}

proc gpt_header(
  current_lba: Int,
  backup_lba: Int,
  first_usable: Int,
  last_usable: Int,
  disk_guid: Bytes,
  entries_lba: Int,
  entry_count: Int,
  entry_size: Int,
  entries_crc: Int,
) [error] -> Result[Bytes] {
  var header = bytes.zero(512)?
  header = put(header, 0, bytes.from_text("EFI PART"))?
  header = put_le(header, 8, 65536, 4)?
  header = put_le(header, 12, 92, 4)?
  header = put_le(header, 24, current_lba, 8)?
  header = put_le(header, 32, backup_lba, 8)?
  header = put_le(header, 40, first_usable, 8)?
  header = put_le(header, 48, last_usable, 8)?
  header = put(header, 56, disk_guid)?
  header = put_le(header, 72, entries_lba, 8)?
  header = put_le(header, 80, entry_count, 4)?
  header = put_le(header, 84, entry_size, 4)?
  header = put_le(header, 88, entries_crc, 4)?
  put_le(header, 16, hash.crc32(header[..92]), 4)?
}

proc write_iso_hybrid_gpt(image: Path, total_sectors: Int, root_start_lba: Int, root_end_lba: Int) [fs, error] {
  let entry_count = 8
  let entry_size = 128
  let entry_sectors = ceil_div(entry_count * entry_size, 512)
  let first_usable = 4
  let last_usable = total_sectors - entry_sectors - 2
  let primary_entries_lba = 2
  let backup_entries_lba = total_sectors - entry_sectors - 1

  let root_type = bytes.from_ints(
    [
      175,
      61,
      198,
      15,
      131,
      132,
      114,
      71,
      142,
      121,
      61,
      105,
      216,
      71,
      125,
      228,
    ],
  )?

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
      gpt_entry(root_type, root_guid, root_start_lba, root_end_lba, "LAPUTA_INSTALLER_ROOT")?,
      bytes.zero(entry_count * entry_size - entry_size)?,
    ],
  )

  let entries_crc = hash.crc32(entries)

  let primary_header = gpt_header(
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

  let backup_header = gpt_header(
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

  let mbr_written = bytes.write_at(image, 0, protective_mbr(total_sectors)?)?
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

  put(data, offset, bytes.from_ints(parts)?)?
}

proc put_both_16(data: Bytes, offset: Int, value: Int) [error] -> Result[Bytes] {
  var out = put_le(data, offset, value, 2)?
  out = put_be(out, offset + 2, value, 2)?
  out
}

proc put_both_32(data: Bytes, offset: Int, value: Int) [error] -> Result[Bytes] {
  var out = put_le(data, offset, value, 4)?
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
  out = put(out, 0, bytes.from_ints([length, 0])?)?
  out = put_both_32(out, 2, extent)?
  out = put_both_32(out, 10, size)?
  out = put(out, 18, iso_datetime_7()?)?
  out = put(out, 25, bytes.from_ints([flags, 0, 0])?)?
  out = put_both_16(out, 28, 1)?
  out = put(out, 32, bytes.from_ints([identifier.len()])?)?
  out = put(out, 33, identifier)?
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
  out = put(out, 0, bytes.from_ints([1, 0])?)?

  if big_endian {
    out = put_be(out, 2, root_extent, 4)?
    out = put_be(out, 6, 1, 2)?
  } else {
    out = put_le(out, 2, root_extent, 4)?
    out = put_le(out, 6, 1, 2)?
  }

  out = put(out, 8, bytes.from_ints([0, 0])?)?
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
  out = put(out, 0, bytes.from_ints([1])?)?
  out = put(out, 1, bytes.from_text("CD001"))?
  out = put(out, 6, bytes.from_ints([1, 0])?)?
  out = put(out, 8, fixed_ascii("LAPUTA", 32)?)?
  out = put(out, 40, fixed_ascii(volume_id, 32)?)?
  out = put_both_32(out, 80, volume_sectors)?
  out = put_both_16(out, 120, 1)?
  out = put_both_16(out, 124, 1)?
  out = put_both_16(out, 128, 2048)?
  out = put_both_32(out, 132, path_table_size)?
  out = put_le(out, 140, path_l, 4)?
  out = put_le(out, 144, 0, 4)?
  out = put_be(out, 148, path_m, 4)?
  out = put_be(out, 152, 0, 4)?
  out = put(out, 156, iso_root_record(root_extent, root_size, 0)?)?
  out = put(out, 190, fixed_ascii(volume_id, 128)?)?
  out = put(out, 318, fixed_ascii("LAPUTA SYSTEMS", 128)?)?
  out = put(out, 446, fixed_ascii("LAPUTA SYSTEMS", 128)?)?
  out = put(out, 574, fixed_ascii("XSH ISO9660 WRITER", 128)?)?
  out = put(out, 702, fixed_ascii("", 37)?)?
  out = put(out, 739, fixed_ascii("", 37)?)?
  out = put(out, 776, fixed_ascii("", 37)?)?
  out = put(out, 813, iso_datetime_17()?)?
  out = put(out, 830, iso_datetime_17()?)?
  out = put(out, 847, repeated_byte(48, 16)?)?
  out = put(out, 863, bytes.from_ints([0])?)?
  out = put(out, 864, repeated_byte(48, 16)?)?
  out = put(out, 880, bytes.from_ints([0, 1])?)?
  out
}

proc iso_terminator() [error] -> Result[Bytes] {
  var out = bytes.zero(2048)?
  out = put(out, 0, bytes.from_ints([255])?)?
  out = put(out, 1, bytes.from_text("CD001"))?
  out = put(out, 6, bytes.from_ints([1])?)?
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

proc build_host() [fs, process, env, error, io] {
  let root = env_path("LAPUTA_ROOT", fs.cwd()?)?
  let arch = normalize_installer_arch(installer_env_value("LAPUTA_INSTALLER_ARCH", "aarch64"))?
  let work = installer_work_path(root, arch)?
  let iso = env_path("LAPUTA_INSTALLER_ISO", fp"{work}/laputa-installer-{arch}.iso")?
  let kernel = env_path("LAPUTA_INSTALLER_KERNEL", fp"{work}/laputa-installer-{arch}.vmlinuz")?
  let kernel_source_raw = installer_env_value("LAPUTA_INSTALLER_KERNEL_SOURCE", "")
  let repo_url = installer_env_value("LAPUTA_REPO_URL", "https://laputa.17166969.xyz")
  let linux_package_name = installer_env_value("LAPUTA_INSTALLER_KERNEL_PACKAGE", "linux")
  let xsh = env_path("XSH_HOST", process.which("xsh")?)?
  let qemu_smoke = installer_env_value("LAPUTA_INSTALLER_QEMU_SMOKE", "0")
  let qemu_authorized_key = installer_env_value("LAPUTA_INSTALLER_QEMU_AUTHORIZED_KEY", "")
  let target_esp_mb = installer_env_value("LAPUTA_TARGET_ESP_MB", "16")
  let installer_root_mb = installer_env_value("LAPUTA_INSTALLER_ROOT_MB", "")
  let installer_ci = installer_env_value("LAPUTA_INSTALLER_CI", "1")

  let package_bundle = package_roots_host.prepare(
    root,
    repo_url,
    linux_package_name,
    qemu_smoke == "1",
    installer_env_value("LAPUTA_INSTALLER_JOBS", "4").parse_int()?,
  )?

  fs.mkdir(work)?

  for path_value in [
    fp"{work}/rootfs-target",
    fp"{work}/rootfs-installer",
    fp"{work}/rootfs-tools",
    fp"{work}/esp",
    fp"{work}/laputa-installer-{arch}.img",
    fp"{work}/laputa-installer-manual-{arch}.img",
    fp"{work}/target-root.tar.gz",
    fp"{work}/target-root.ext4",
    fp"{work}/target-esp.vfat",
    fp"{work}/linux-kernel",
  ] {
    remove_tree(path_value)?
  }

  fs.mkdir(fp"{work}/rootfs-target")?
  fs.mkdir(fp"{work}/rootfs-installer")?
  assemble_composed_roots(root, work, package_bundle)?

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

  prune_runtime_root(fp"{work}/rootfs-target")?
  prune_runtime_root(fp"{work}/rootfs-installer")?
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

proc main(...argv: List[Str]) [fs, process, env, error, io] {
  if argv.len() > 0 {
    return Err(InstallerBuildError.Failed("build-installer-image.xsh does not accept subcommands"))
  }

  build_host()?
}

main(@args)?
