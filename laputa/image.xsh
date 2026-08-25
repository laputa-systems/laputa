##! Deterministic ext4 sizing and atomic GPT disk construction for Laputa generations.
use laputa.types as types

# The byte size of one GPT sector.
let sector_size = 512

# The first aligned sector assigned to the root filesystem.
let root_start_lba = 2048

## Return the root partition UUID shared by GPT and the ARM kernel command line.
export pure image_root_partuuid() -> Str {
  "33333333-3333-3333-3333-333333333333"
}

## Parse a byte count or a whole-MiB string without accepting ambiguous units.
export proc parse_size_bytes(value: Str) [error] -> Result[Int] {
  let trimmed = value.trim()
  if trimmed.ends_with("M") {
    let mebibytes = trimmed.replace("M", "").parse_int()?
    if mebibytes <= 0 {
      return Err(types.LaputaError.Profile(f"image size must be positive: ${value}"))
    }
    return mebibytes * 1024 * 1024
  }

  let byte_count = trimmed.parse_int()?
  if byte_count <= 0 {
    return Err(types.LaputaError.Profile(f"image size must be positive: ${value}"))
  }
  return byte_count
}

## Calculate a graphical rootfs size from used bytes, rounded to MiB with a 256-MiB floor.
export pure rootfs_size_bytes(used_bytes: Int) -> Int {
  let raw = used_bytes + used_bytes / 4 + 64 * 1024 * 1024
  let mib = 1024 * 1024
  let rounded = ((raw + mib - 1) / mib) * mib
  if rounded < 256 * mib {
    return 256 * mib
  }

  return rounded
}

# Replaces an exact byte range inside an immutable byte value.
proc put(data: Bytes, offset: Int, replacement: Bytes) [error] -> Result[Bytes] {
  bytes.concat(
    [
      data.slice(offset: 0, length: offset),
      replacement,
      data.slice(offset: offset + replacement.len(), length: data.len() - offset - replacement.len()),
    ],
  )
}

# Encodes an unsigned little-endian integer at an exact byte range.
proc put_le(data: Bytes, offset: Int, value: Int, width: Int) [error] -> Result[Bytes] {
  put(data, offset, bytes.pack_le(value, width)?)
}

# Encodes a GPT UTF-16LE partition name with its fixed 72-byte width.
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

# Encodes one GPT partition entry.
proc gpt_entry(type_guid: Bytes, part_guid: Bytes, start_lba: Int, end_lba: Int, name: Str) [error] -> Result[Bytes] {
  var entry = bytes.zero(128)?
  entry = put(entry, 0, type_guid)?
  entry = put(entry, 16, part_guid)?
  entry = put_le(entry, 32, start_lba, 8)?
  entry = put_le(entry, 40, end_lba, 8)?
  put(entry, 56, gpt_name(name)?)
}

## Construct a protective MBR covering the complete disk.
export proc protective_mbr(total_sectors: Int) [error] -> Result[Bytes] {
  if total_sectors <= 1 {
    return Err(types.LaputaError.Profile("GPT disk needs at least two sectors"))
  }
  var sector = bytes.zero(sector_size)?
  sector = put(sector, 447, bytes.from_ints([0, 2, 0])?)?
  sector = put(sector, 450, bytes.from_ints([238])?)?
  sector = put(sector, 451, bytes.from_ints([255, 255, 255])?)?
  sector = put_le(sector, 454, 1, 4)?
  sector = put_le(sector, 458, total_sectors - 1, 4)?
  put(sector, 510, bytes.from_ints([85, 170])?)
}

# Constructs one GPT header with a correct header checksum.
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
  var header = bytes.zero(sector_size)?
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
  put_le(header, 16, hash.crc32(header.slice(offset: 0, length: 92)), 4)
}

# Returns the fixed Linux filesystem partition type GUID in GPT byte order.
proc root_type_guid() [error] -> Result[Bytes] {
  bytes.from_ints([175, 61, 198, 15, 131, 132, 114, 71, 142, 121, 61, 105, 216, 71, 125, 228])
}

## Return the root partition GUID in GPT byte order.
export proc root_partition_guid() [error] -> Result[Bytes] {
  bytes.from_ints([51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51, 51])
}

## Verify the GPT signatures, root GUID, and partition bounds before publication.
export proc verify_disk(image: Path, rootfs_bytes: Int) [fs, error] {
  let metadata = fs.metadata(image)?
  if metadata.size <= rootfs_bytes {
    return Err(types.LaputaError.Profile(f"disk image is too small: ${image}"))
  }
  let mbr = bytes.read_at(image, 510, 2)?
  if mbr != bytes.from_ints([85, 170])? {
    return Err(types.LaputaError.Profile(f"${image} has no protective MBR signature"))
  }
  let header = bytes.read_at(image, sector_size, 8)?
  if header != bytes.from_text("EFI PART") {
    return Err(types.LaputaError.Profile(f"${image} has no GPT header signature"))
  }
  let entry = bytes.read_at(image, 2 * sector_size, 128)?
  let guid = entry.slice(offset: 16, length: 16)
  if guid != root_partition_guid()? {
    return Err(types.LaputaError.Profile(f"${image} root partition GUID does not match ${image_root_partuuid()}"))
  }
  let start = bytes.unpack_le(entry, 8, offset: 32)?
  let end = bytes.unpack_le(entry, 8, offset: 40)?
  if start != root_start_lba or end < start or (end - start + 1) * sector_size < rootfs_bytes {
    return Err(types.LaputaError.Profile(f"${image} has invalid root partition bounds"))
  }
}

## Write and fully verify a GPT disk in a sibling temporary path before atomic publication.
export proc write_disk(rootfs: Path, image: Path) [fs, error] {
  let rootfs_bytes = fs.metadata(rootfs)?.size
  if rootfs_bytes <= 0 or rootfs_bytes % sector_size != 0 {
    return Err(types.LaputaError.Profile(f"rootfs must be nonempty and sector aligned: ${rootfs}"))
  }
  let rootfs_sectors = rootfs_bytes / sector_size
  let entry_count = 128
  let entry_size = 128
  let entry_sectors = 32
  let total_sectors = rootfs_sectors + 65536
  let first_usable = 2 + entry_sectors
  let last_usable = total_sectors - entry_sectors - 2
  let root_end = root_start_lba + rootfs_sectors - 1
  if root_end > last_usable {
    return Err(types.LaputaError.Profile("root filesystem does not fit GPT disk layout"))
  }
  let backup_entries_lba = total_sectors - entry_sectors - 1
  let tmp = fp"${image}.tmp"
  fs.mkdir(image.parent)?
  fs.remove(tmp, missing_ok: true)?
  defer fs.remove(tmp, missing_ok: true)?
  fs.write(tmp, b"")?
  tmp.truncate(total_sectors * sector_size)?
  let entries = bytes.concat([
    gpt_entry(root_type_guid()?, root_partition_guid()?, root_start_lba, root_end, "LAPUTA_ROOT")?,
    bytes.zero(entry_count * entry_size - entry_size)?,
  ])
  let entries_crc = hash.crc32(entries)
  let disk_guid = bytes.zero(16)?
  let primary_header = gpt_header(1, total_sectors - 1, first_usable, last_usable, disk_guid, 2, entry_count, entry_size, entries_crc)?
  let backup_header = gpt_header(total_sectors - 1, 1, first_usable, last_usable, disk_guid, backup_entries_lba, entry_count, entry_size, entries_crc)?
  let _ = bytes.write_at(tmp, 0, protective_mbr(total_sectors)?)?
  let _ = bytes.write_at(tmp, sector_size, primary_header)?
  let _ = bytes.write_at(tmp, 2 * sector_size, entries)?
  let _ = bytes.write_at(tmp, backup_entries_lba * sector_size, entries)?
  let _ = bytes.write_at(tmp, (total_sectors - 1) * sector_size, backup_header)?
  let _ = bytes.copy_file(rootfs, tmp, source_offset: 0, dest_offset: root_start_lba * sector_size, length: rootfs_bytes, create: false, truncate: false)?
  fs.fsync(tmp)?
  verify_disk(tmp, rootfs_bytes)?
  fs.rename(tmp, image, overwrite: true)?
  verify_disk(image, rootfs_bytes)?
}
