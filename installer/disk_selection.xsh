##! Inspect CI target partitions through the Linux block-device sysfs tree.
## Report whether any disk has a partition with the target PARTUUID.
export proc ci_target_installed(sys_block: Path, disks: List[Path], target_partuuid: Str) [fs, error] -> Result[Bool, Error] {
  for disk in disks {
    let block = fp"{sys_block}/{disk.name}"
    for entry in fs.children(block)? {
      if entry.kind == "dir" and entry.name.starts_with(disk.name) {
        let partition_marker = fp"{block}/{entry.name}/partition"
        let uevent = fp"{block}/{entry.name}/uevent"

        if partition_marker.exists()? and uevent.exists()? {
          return true when f"PARTUUID={target_partuuid}" in uevent.read_text()?
        }
      }
    }
  }

  false
}
