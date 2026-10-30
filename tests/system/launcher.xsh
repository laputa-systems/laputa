##! Host launcher selection from the activation record.
use system.activation
use system.build
use system.launcher
use system.qemu
use system.types
use profiles.qemu-maintained as maintained

proc sha256_text(text: Str) -> Str {
  bytes.from_text(text).sha256().hex()
}

proc generation(id: Str) -> activation.GenerationReceipt {
  {id: id, kernel: f"boot/vmlinuz-{id}", root_digest: sha256_text(id)}
}

proc image_admission(id: Str) -> activation.ImageAdmission {
  {generation: generation(id), state_format: activation.ACTIVATION_STATE_FORMAT, kernel_sha256: sha256_text(f"kernel-{id}\n"), disk_sha256: sha256_text(f"disk-{id}\n")}
}

proc admission_policy() -> activation.AdmissionPolicy {
  {revision: 1, images: [image_admission(id) for id in ["a", "b", "c", "orphan"]]}
}

proc state_dir(ctx: TestContext, name: Str) -> Result[Path, Error] {
  test.temp_dir(ctx, name:)
}

proc write_image(state: Path, id: Str) {
  let kernel = fp"{state}/inputs/{id}/kernel"
  let disk = fp"{state}/inputs/{id}/disk"
  kernel.parent.mkdir()
  kernel.write(f"kernel-{id}\n")
  disk.write(f"disk-{id}\n")
  let _ = activation.activation_publish_image(state, generation(id), kernel, disk, activation.ACTIVATION_STATE_FORMAT)?
}

proc install_a(state: Path) {
  write_image(state, "a")
  activation.activation_install(state, generation("a"), admission_policy())
}

proc stage_b(state: Path) {
  write_image(state, "b")
  activation.activation_stage(state, generation("b"))
}

test test_tampered_pending_image_does_not_consume_an_attempt [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-tampered")?
  install_a(state)
  stage_b(state)
  let before = record_text(state)?
  fp"{state}/images/b/disk".write("tampered\n")
  match launcher.launcher_select(state) {
    Ok(_) => assert false, "tampered image selected"
    Err(problem) => assert "generation image digest differs" in problem.message
  }
  assert record_text(state)? == before
}

test test_image_publication_never_replaces_a_retained_generation [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-publish")?
  write_image(state, "a")
  let before = fp"{state}/images/a/kernel".read_text()?
  fp"{state}/inputs/a/kernel".write("replacement")
  match activation.activation_publish_image(state, generation("a"), fp"{state}/inputs/a/kernel", fp"{state}/inputs/a/disk", activation.ACTIVATION_STATE_FORMAT) {
    Ok(_) => assert false, "retained generation replaced"
    Err(_) => {}
  }
  assert fp"{state}/images/a/kernel".read_text()? == before
}

test test_pending_kernel_tampering_is_rejected_without_a_write [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-kernel-tampered")?
  install_a(state)
  stage_b(state)
  let before = record_text(state)?
  fp"{state}/images/b/kernel".write("tampered kernel")
  match launcher.launcher_select(state) {
    Ok(_) => assert false
    Err(problem) => assert "generation image digest differs" in problem.message
  }
  assert record_text(state)? == before
}

test test_image_receipt_must_match_before_staging [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-receipt-mismatch")?
  install_a(state)
  write_image(state, "b")
  let before = record_text(state)?
  match activation.activation_stage(state, {...generation("b"), root_digest: sha256_text("different")}) {
    Ok(_) => assert false
    Err(problem) => assert "generation image receipt differs" in problem.message
  }
  assert record_text(state)? == before
}

test test_incomplete_publication_does_not_install_an_image [fs, error] { |ctx|
  let state = state_dir(ctx, "launcher-incomplete")?
  let source = fp"{state}/kernel"
  source.write("kernel")
  match activation.activation_publish_image(state, generation("a"), source, fp"{state}/missing", activation.ACTIVATION_STATE_FORMAT) {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert ! fp"{state}/images/a".exists()?
}

test test_missing_maintained_state_does_not_consume_an_attempt [fs, time, error] { |ctx|
  let root = state_dir(ctx, "launcher-state-missing")?
  let state = fp"{root}/generations"
  state.mkdir()
  install_a(state)
  stage_b(state)
  let before = record_text(state)?
  let target = qemu.qemu_target("Linux", "x86_64")?
  let config = qemu.QemuConfig(qemu: fp"{target.qemu_name}", python: p"python3", qmp_helper: p"boot/qmp-proof.py", target:)
  let outputs = build.outputs(root)
  match qemu.boot_command_argv(config, maintained.profile, outputs, types.Test, state) {
    Ok(_) => assert false
    Err(problem) => assert "maintained state image is missing" in problem.message
  }
  assert record_text(state)? == before
  let argv = qemu.qemu_command_argv(config, maintained.profile, outputs, types.Test)
  assert f"if=none,id=state,format=raw,file={root}/state.ext4" in argv
  fp"{root}/state.ext4".write("state", mode: 0o644)
  match qemu.boot_command_argv(config, maintained.profile, outputs, types.Test, state) {
    Ok(_) => assert false, "public state image accepted"
    Err(problem) => assert "maintained state image must be private" in problem.message
  }
  assert record_text(state)? == before
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
  install_a(state)
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
  install_a(state)
  stage_b(state)
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
  install_a(state)
  stage_b(state)
  fp"{state}/images/b/disk".remove()
  let before = record_text(state)?

  match launcher.launcher_select(state) {
    Ok(_) => assert false
    Err(_) => {}
  }

  assert record_text(state)? == before
}

test test_attempt_cap_selects_the_fallback_image [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-fallback")?
  install_a(state)
  stage_b(state)
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
  install_a(state)
  let record = activation.activation_status(state)?
  fp"{state}/{activation.ACTIVATION_RECORD_NAME}".write(json.encode({...record, current: {...generation("a"), id: "a/b"}})?)
  let before = record_text(state)?
  assert launcher.launcher_select(state) is Err(_)
  assert record_text(state)? == before
}

test test_generation_path_with_a_comma_is_rejected [error] {
  let image = {
    boot_serial: 0,
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

test test_qemu_boot_command_selects_pending_generation [fs, time, error] { |ctx|
  let state = state_dir(ctx, "launcher-qemu")?
  install_a(state)
  stage_b(state)
  fp"{state}/images/a".remove()
  let target = qemu.qemu_target("Linux", "x86_64")?
  let config = qemu.QemuConfig(qemu: fp"{target.qemu_name}", python: p"python3", qmp_helper: p"boot/qmp-proof.py", target:)
  let profile = types.SystemProfile(
    name: "qemu-dwl-foot", package_roots: ["baselayout"], kernel_package: "linux", kernel_path: p"boot/vmlinuz",
    qemu_smp: 2, qemu_memory: "1536M", qemu_width: 1280, qemu_height: 800,
    forbidden_packages: [], forbidden_sonames: [], development: true,
    proof: {cmdline_flag: "LAPUTA_QEMU_DWL_FOOT_PROOF", ready_marker: "LAPUTA_DWL_FOOT_PROOF_READY", success_marker: "LAPUTA_DWL_FOOT_PROOF_OK", failure_marker: "LAPUTA_DWL_FOOT_PROOF_FAILED", vt_away_marker: "", vt_back_marker: ""},
  )
  let outputs = build.outputs(p"target/laputa/launcher-fixture")
  assert qemu.boot_command_argv(config, profile, outputs, types.Test, null)? == qemu.qemu_command_argv(config, profile, outputs, types.Test)
  let argv = qemu.boot_command_argv(config, profile, outputs, types.Test, state)?
  assert_image(argv, {boot_serial: 0, id: "b", kernel_file: fp"{state}/images/b/kernel", disk_file: fp"{state}/images/b/disk"})
  assert ! (outputs.kernel.display() in argv)
  assert argv |> any "LAPUTA_GENERATION_ID=b LAPUTA_BOOT_SERIAL=1" in .
  assert activation.activation_status(state)?.boot_attempts == 1
}
