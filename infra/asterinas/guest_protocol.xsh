##! The guest markers the host requires before accepting an Asterinas proof.

## The guest serial proof must show each step from the initramfs handoff through XSH.
export const guest_success_markers = [
  "LAPUTA_ASTERINAS_INITRAMFS_START",
  "LAPUTA_ASTERINAS_SYSFS_MOUNT_OK",
  "LAPUTA_ASTERINAS_EXT2_MOUNT_OK",
  "LAPUTA_ASTERINAS_NEWROOT_LAYOUT_OK",
  "LAPUTA_ASTERINAS_PSEUDO_MOUNTS_MOVED_OK",
  "LAPUTA_ASTERINAS_SWITCH_ROOT_START",
  "LAPUTA_ASTERINAS_NEWROOT_CHDIR_OK",
  "LAPUTA_ASTERINAS_CHROOT_OK",
  "LAPUTA_ASTERINAS_ROOT_INIT_SCRIPT_START",
  "LAPUTA_ASTERINAS_BOOT_SETUP_START",
  "LAPUTA_ASTERINAS_BOOT_SETUP_OK",
  "LAPUTA_ASTERINAS_XINIT_PID1_OK",
  "LAPUTA_ASTERINAS_ROOTFS_OK",
  "LAPUTA_ASTERINAS_XSH_OK",
  "LAPUTA_ASTERINAS_TEST_OK",
]

## Return every required marker that is absent from the captured serial log.
export pure guest_missing_success_markers(output: Str) -> List[Str] {
  [marker for marker in guest_success_markers if !(marker in output)]
}
