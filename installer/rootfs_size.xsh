##! Sizing for installer ext4 images written by laputa-fs.

const ext4_block_size = 4096
const ext4_blocks_per_group = 32768
const ext4_group_metadata_blocks = 516
const blocks_per_mib = 1MiB / ext4_block_size
const minimum_image_mib = 8

pure ceil_div(value: Int, divisor: Int) -> Int {
  (value + divisor - 1) / divisor
}

## Estimate the ext4 blocks a tree occupies, including directory entries and indirect blocks.
export proc tree_blocks(path_value: Path) [fs, error] -> Result[Int, Error] {
  let meta = path_value.metadata()?

  if meta.kind != "dir" {
    let data = ceil_div(meta.size, ext4_block_size)
    return data + ceil_div(data, 1024) + 1
  }

  let children = fs.children(path_value)?.collect()
  var total = 1 + ceil_div(children.len() * 264, ext4_block_size)

  for child in children {
    total += if child.kind == "symlink" { 1 } else { tree_blocks(child.path)? }
  }

  total
}

## Return an image size with enough room for data and the final group's metadata.
export pure image_size_mib(data_blocks: Int) -> Int {
  let groups = ceil_div(data_blocks, ext4_blocks_per_group - ext4_group_metadata_blocks)
  let needed_mib = ceil_div(
    (data_blocks + groups * ext4_group_metadata_blocks) * ext4_block_size,
    1MiB,
  ) + 1
  let last_group_blocks = needed_mib * blocks_per_mib % ext4_blocks_per_group

  let padded_mib = if last_group_blocks > 0 and last_group_blocks < ext4_group_metadata_blocks {
    needed_mib + ceil_div(ext4_group_metadata_blocks - last_group_blocks, blocks_per_mib)
  } else {
    needed_mib
  }

  return minimum_image_mib when padded_mib < minimum_image_mib

  padded_mib
}

## Size a partition of 512-byte sectors for mkfs.ext4: whole blocks, without a
## final block group too small to hold its own metadata.
export pure ext4_partition_sectors(available_sectors: Int) -> Int {
  let sectors_per_block = ext4_block_size / 512
  let blocks = available_sectors / sectors_per_block
  let last_group_blocks = blocks % ext4_blocks_per_group
  let usable_blocks = if last_group_blocks > 0 and last_group_blocks < ext4_group_metadata_blocks {
    blocks - last_group_blocks
  } else {
    blocks
  }

  usable_blocks * sectors_per_block
}
