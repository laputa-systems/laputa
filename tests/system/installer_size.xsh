use installer.rootfs_size

test test_installer_root_size_keeps_the_last_ext4_group_metadata {
  assert rootfs_size.image_size_mib(32252) == 131
}
