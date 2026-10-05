use installer.rootfs_size as rootfs_size

test test_installer_root_size_keeps_the_last_ext4_group_metadata {
  # One block group's usable capacity used to produce a 129 MiB image with
  # only 256 blocks in its final group, too few for the inode table.
  assert rootfs_size.image_size_mib(32252) == 131
}
