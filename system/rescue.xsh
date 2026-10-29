##! Decide detached ext repair and an independent rescue command.
## Caller-supplied attachment of the filesystem being repaired.
export enum RescueMount { RescueUnmounted, RescueReadOnly, RescueWritable }

## e2fsck outcome for a detached filesystem. Unrecoverable does not claim the previous bytes were preserved.
export enum RescueClass { RescueClean, RescueRepaired, RescueUnrecoverable, RescueFailed }

## Repair refused because the caller reported a writable mount.
export error RescueError = RescueMountedWritable : InvalidData

## Rescue guest image, detached disk, and the command that repairs it.
export type RescuePlan = {image: Path, disk: Path, command: List[Str]}

pure rescue_detached(mount: RescueMount) -> Result[Unit, Error] {
  guard mount != .RescueWritable else {
    return Err(RescueError.RescueMountedWritable("refusing to repair a filesystem mounted writable"))
  }
}

## Preen argv for an unmounted or read-only volume. A writable mount is an error and yields no argv.
export pure rescue_repair_argv(checker: Path, device: Path, mount: RescueMount) -> Result[List[Str], Error] {
  rescue_detached(mount)
  [checker.display(), "-f", "-p", device.display()]
}

## Classify an e2fsck status for a detached volume. Exit 2 is repaired. A writable mount is an error.
export pure rescue_classify(status: Int, mount: RescueMount) -> Result[RescueClass, Error] {
  rescue_detached(mount)
  match status {
    0 => RescueClean
    1 | 2 => RescueRepaired
    4 | 8 => RescueUnrecoverable
    else => RescueFailed
  }
}

pure drive_text(file: Path) -> Result[Str, Error] {
  let text = file.display()

  guard ! ("," in text or " " in text or "\n" in text or "\t" in text) else {
    fail "rescue path cannot contain a comma or whitespace"
  }

  text
}

## QEMU arguments that attach a rescue image and a detached disk. Repair stays a separate e2fsck argv.
export pure rescue_plan(image: Path, disk: Path) -> Result[RescuePlan, Error] {
  let image_text = drive_text(image)?
  let disk_text = drive_text(disk)?

  {
    image,
    disk,
    command: [
      "-display",
      "none",
      "-serial",
      "stdio",
      "-drive",
      f"if=none,id=rescue,format=raw,readonly=on,file={image_text}",
      "-device",
      "virtio-blk-pci,drive=rescue",
      "-drive",
      f"if=none,id=broken,format=raw,file={disk_text}",
      "-device",
      "virtio-blk-pci,drive=broken",
    ],
  }
}
