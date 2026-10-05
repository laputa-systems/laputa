##! Sizing for installer ext4 images written by laputa-fs.

const ext4_block_size = 4096
const ext4_blocks_per_group = 32768
const ext4_group_metadata_blocks = 516
const blocks_per_mib = 1024 * 1024 / ext4_block_size
const minimum_image_mib = 8

pure ceil_div(value: Int, divisor: Int) -> Int {
  (value + divisor - 1) / divisor
}

## Return an image size with enough room for data and the final group's metadata.
export pure image_size_mib(data_blocks: Int) -> Int {
  let groups = ceil_div(data_blocks, ext4_blocks_per_group - ext4_group_metadata_blocks)
  let needed_mib = ceil_div(
    (data_blocks + groups * ext4_group_metadata_blocks) * ext4_block_size,
    1024 * 1024,
  ) + 1
  let last_group_blocks = needed_mib * blocks_per_mib % ext4_blocks_per_group

  # Each group needs four header blocks and a 512-block inode table. A partial
  # final group below that size would truncate its inode table in the image.
  let padded_mib = if last_group_blocks > 0 and last_group_blocks < ext4_group_metadata_blocks {
    needed_mib + ceil_div(ext4_group_metadata_blocks - last_group_blocks, blocks_per_mib)
  } else {
    needed_mib
  }

  return minimum_image_mib when padded_mib < minimum_image_mib

  padded_mib
}
