##! Host selection of the generation a direct-kernel boot runs.
use system.activation

## Host files for one generation id. The activation receipt stays the identity.
export type LauncherImage = {
  boot_serial: Int,
  id: Str,
  kernel_file: Path,
  disk_file: Path,
}

pure selected_image(image: activation.GenerationImage, serial: Int) -> LauncherImage {
  {id: image.id, kernel_file: image.kernel_file, disk_file: image.disk_file, boot_serial: serial}
}

pure drive_text(file: Path) -> Result[Str, Error] {
  let text = file.display()

  guard ! ("," in text or " " in text or "\n" in text or "\t" in text) else {
    fail "generation path cannot contain a comma or whitespace"
  }

  text
}

## The state directory when this profile output root has an activation record.
export proc launcher_state(output_root: Path) [fs, error] -> Result[Path?, Error] {
  let state_dir = fp"{output_root}/generations"

  if fp"{state_dir}/{activation.ACTIVATION_RECORD_NAME}".exists() {
    state_dir
  } else {
    null
  }
}

## Boot the current generation, or count one pending attempt and boot that receipt.
export proc launcher_select(state_dir: Path) [fs, time, error] -> Result[LauncherImage, Error] {
  let record = activation.activation_status(state_dir)?

  if record.pending == null {
    let current = activation.activation_verify_image(state_dir, record.current)?
    return selected_image(current, record.boot_serial)
  }

  let anticipated = if record.boot_attempts >= activation.ACTIVATION_MAX_BOOT_ATTEMPTS {
    record.fallback
  } else {
    record.pending
  }
  let image = activation.activation_verify_image(state_dir, anticipated)?
  let choice = activation.activation_begin_boot(state_dir)?
  let selected = match choice {
    activation.PendingBoot(id) => id
    activation.FellBack(id) => id
  }

  guard selected.id == image.id else {
    fail "activation selection changed"
  }

  selected_image(image, selected.serial)
}

pure rewrite_kernel(argv: List[Str], kernel: Str) -> Result[List[Str], Error] {
  var seen = 0
  var index = 0
  let rewritten = collect {
    while index < argv.len() {
      if argv[index] == "-kernel" {
        guard index + 1 < argv.len() else {
          fail "kernel argument is missing"
        }

        seen += 1
        yield "-kernel"
        yield kernel
        index += 2
      } else {
        yield argv[index]
        index += 1
      }
    }
  }

  guard seen == 1 else {
    fail "launcher expects one kernel"
  }

  rewritten
}

pure rewrite_root_drive(element: Str, disk: Str) -> Result[Str, Error] {
  guard element.starts_with("if=none,id=root,") else {
    fail "not the root drive"
  }

  var seen = 0
  let parts = collect {
    for part in element.split(",") {
      if part.starts_with("file=") {
        seen += 1
        yield f"file={disk}"
      } else {
        yield part
      }
    }
  }

  guard seen == 1 else {
    fail "root drive file is missing"
  }

  parts.join(",")
}

## Replace the kernel and root disk in an existing QEMU argv. Every other argument stays.
export pure launcher_qemu_argv(argv: List[Str], image: LauncherImage) -> Result[List[Str], Error] {
  let kernel = drive_text(image.kernel_file)?
  let disk = drive_text(image.disk_file)?
  let with_kernel = rewrite_kernel(argv, kernel)?
  var seen = 0
  let rewritten = collect {
    for element in with_kernel {
      if element.starts_with("if=none,id=root,") {
        seen += 1
        yield rewrite_root_drive(element, disk)?
      } else {
        yield element
      }
    }
  }

  guard seen == 1 else {
    fail "launcher expects one root drive"
  }

  rewritten
}
