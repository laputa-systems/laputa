##! Host selection of the generation a direct-kernel boot runs.
use system.activation

const generation_id_re = rx"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"

type ImageReceipt = {
  format: Str,
  generation: activation.GenerationReceipt,
  kernel_sha256: Str,
  disk_sha256: Str,
}

## Host files for one generation id. The activation receipt stays the identity.
export type LauncherImage = {
  boot_serial: Int,
  id: Str,
  kernel_file: Path,
  disk_file: Path,
}

## Publish already verified inputs under a new id without replacing retained images.
export proc launcher_publish_image(state_dir: Path, receipt: activation.GenerationReceipt, kernel: Path, disk: Path) [fs, error] {
  guard generation_id_ok(receipt.id) else { fail "generation id is not a single path segment" }
  let images = fp"{state_dir}/images"
  images.mkdir()
  fs.fsync(state_dir)
  let temporary = fs.tempdir_in(images)?
  let bundle = fp"{temporary.host_path()?}/bundle"
  bundle.mkdir()
  kernel.copy(to: fp"{bundle}/kernel")
  disk.copy(to: fp"{bundle}/disk")
  let metadata = ImageReceipt(
    format: "laputa-activation-image-1",
    generation: receipt,
    kernel_sha256: hash.sha256(fp"{bundle}/kernel")?.hex(),
    disk_sha256: hash.sha256(fp"{bundle}/disk")?.hex(),
  )
  fp"{bundle}/receipt.json".write(json.encode(metadata)? + "\n")
  for item in [p"kernel", p"disk", p"receipt.json"] { fs.fsync(fp"{bundle}/{item}") }
  fs.fsync(bundle)
  bundle.rename(to: fp"{images}/{receipt.id}", overwrite: false)
  fs.fsync(images)
}

proc verify_image(image: LauncherImage, receipt: activation.GenerationReceipt) {
  let metadata = json.read(fp"{image.kernel_file.parent}/receipt.json")?.require_exact(ImageReceipt)?
  guard metadata.format == "laputa-activation-image-1" and metadata.generation == receipt else {
    fail "generation image receipt differs"
  }
  guard hash.sha256(image.kernel_file)?.hex() == metadata.kernel_sha256 and hash.sha256(image.disk_file)?.hex() == metadata.disk_sha256 else {
    fail "generation image digest differs"
  }
}

proc generation_id_ok(id: Str) -> Bool {
  generation_id_re.matches(id)
}

pure drive_text(file: Path) -> Result[Str, Error] {
  let text = file.display()

  guard ! ("," in text or " " in text or "\n" in text or "\t" in text) else {
    fail "generation path cannot contain a comma or whitespace"
  }

  text
}

## Image paths for a generation id under the activation state directory.
export proc launcher_image_files(state_dir: Path, id: Str) [fs, error] -> Result[LauncherImage, Error] {
  guard generation_id_ok(id) else {
    fail "generation id is not a single path segment"
  }

  let kernel_file = fp"{state_dir}/images/{id}/kernel"
  let disk_file = fp"{state_dir}/images/{id}/disk"

  guard kernel_file.exists() and disk_file.exists() else {
    fail "generation image is missing"
  }

  {id, kernel_file, disk_file, boot_serial: 0}
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
    let current = launcher_image_files(state_dir, record.current.id)?
    verify_image(current, record.current)
    return {...current, boot_serial: record.boot_serial}
  }

  let anticipated = if record.boot_attempts >= activation.ACTIVATION_MAX_BOOT_ATTEMPTS {
    record.fallback
  } else {
    record.pending
  }
  let image = launcher_image_files(state_dir, anticipated.id)?
  verify_image(image, anticipated)
  let choice = activation.activation_begin_boot(state_dir)?
  let selected = match choice {
    activation.PendingBoot(id) => id
    activation.FellBack(id) => id
  }

  guard selected.id == image.id else {
    fail "activation selection changed"
  }

  {...image, boot_serial: selected.serial}
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
