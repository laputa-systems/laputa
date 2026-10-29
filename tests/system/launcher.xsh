##! Host launcher selection from the activation record.
use system.activation
use system.launcher

proc sha256_text(text: Str) -> Str {
  bytes.from_text(text).sha256().hex()
}

proc generation(id: Str) -> activation.GenerationReceipt {
  {id: id, kernel: f"boot/vmlinuz-{id}", root_digest: sha256_text(id)}
}

proc state_dir(ctx: TestContext, name: Str) -> Result[Path, Error] {
  test.temp_dir(ctx, name:)
}

proc write_image(state: Path, id: Str) {
  let kernel = fp"{state}/images/{id}/kernel"
  let disk = fp"{state}/images/{id}/disk"
  kernel.parent.mkdir()
  kernel.write(f"kernel-{id}\n")
  disk.write(f"disk-{id}\n")
}

proc record_text(state: Path) -> Result[Str, Error] {
  fp"{state}/{activation.ACTIVATION_RECORD_NAME}".read_text()
}

pure sample_argv() -> List[Str] {
  [
    "qemu-system-x86_64",
    "-kernel",
    "current/vmlinuz",
    "-drive",
    "if=none,id=root,format=raw,file=current/disk.img,snapshot=on",
    "-netdev",
    "user,id=net0",
  ]
}

proc assert_image(argv: List[Str], image: launcher.LauncherImage) {
  var index = 0
  var kernel = ""

  while index < argv.len() {
    if argv[index] == "-kernel" and index + 1 < argv.len() {
      kernel = argv[index + 1]
    }

    index += 1
  }

  assert kernel == image.kernel_file.display()
  assert argv |> any . == f"if=none,id=root,format=raw,file={image.disk_file},snapshot=on"
  assert "user,id=net0" in argv
}

test test_current_generation_boots_without_a_pending_write [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-current")?
  activation.activation_install(state, generation("a"))
  write_image(state, "a")
  let before = record_text(state)?
  let image = launcher.launcher_select(state)?
  let argv = launcher.launcher_qemu_argv(sample_argv(), image)?

  assert image.id == "a"
  assert_image(argv, image)
  assert record_text(state)? == before
  assert launcher.launcher_select(state)?.id == "a"
}

test test_pending_boot_uses_the_staged_image_and_counts_an_attempt [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-pending")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  write_image(state, "a")
  write_image(state, "b")
  let image = launcher.launcher_select(state)?
  let argv = launcher.launcher_qemu_argv(sample_argv(), image)?
  let record = activation.activation_status(state)?

  assert image.id == "b"
  assert_image(argv, image)
  assert record.boot_attempts == 1
  assert record.last_operation == "pending-boot"
  assert record.current.id == "a"
}

test test_missing_image_does_not_consume_an_attempt [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-missing")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  write_image(state, "a")
  let before = record_text(state)?

  match launcher.launcher_select(state) {
    Ok(_) => assert false
    Err(_) => {}
  }

  assert record_text(state)? == before
}

test test_attempt_cap_selects_the_fallback_image [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-fallback")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  write_image(state, "a")
  write_image(state, "b")
  let first = launcher.launcher_select(state)?
  let second = launcher.launcher_select(state)?
  let third = launcher.launcher_select(state)?
  let record = activation.activation_status(state)?

  assert first.id == "b"
  assert second.id == "b"
  assert third.id == "a"
  assert record.pending == null
  assert record.current.id == "a"
  assert record.last_operation == "fell-back"
  assert_image(launcher.launcher_qemu_argv(sample_argv(), third)?, third)
}

test test_unsafe_generation_id_is_rejected_without_a_write [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-id")?
  activation.activation_install(state, {...generation("a"), id: "a/b"})
  write_image(state, "a")
  let before = record_text(state)?

  match launcher.launcher_select(state) {
    Ok(_) => assert false
    Err(_) => {}
  }

  assert record_text(state)? == before
}

test test_generation_path_with_a_comma_is_rejected [error] {
  let image = {
    id: "a",
    kernel_file: p"/var/laputa/kernel",
    disk_file: p"/var/laputa/disk,img",
  }

  match launcher.launcher_qemu_argv(sample_argv(), image) {
    Ok(_) => assert false
    Err(_) => {}
  }
}

test test_launcher_state_follows_the_activation_record [fs, error] { |ctx|
  let root = state_dir(ctx, "launcher-root")?
  assert launcher.launcher_state(root)? == null
  let state = fp"{root}/generations"
  state.mkdir()
  fp"{state}/{activation.ACTIVATION_RECORD_NAME}".write("{}\n")
  assert launcher.launcher_state(root)? == state
}
