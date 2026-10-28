use installer.rootfs_size

test test_installer_root_size_keeps_the_last_ext4_group_metadata {
  assert rootfs_size.image_size_mib(32252) == 131
}

test test_installer_root_partition_drops_a_final_group_too_small_for_metadata {
  let group_sectors = 32768 * 8
  assert rootfs_size.ext4_partition_sectors(4 * group_sectors) == 4 * group_sectors
  assert rootfs_size.ext4_partition_sectors(4 * group_sectors + 515 * 8 + 7) == 4 * group_sectors
  assert rootfs_size.ext4_partition_sectors(4 * group_sectors + 516 * 8 + 7) == 4 * group_sectors + 516 * 8
}
