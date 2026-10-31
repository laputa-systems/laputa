##! Trusted local activation inputs for the SSH reply-loss drill.
use system.activation
use system.launcher

pure receipt(id: Str) -> activation.GenerationReceipt {
  {id, kernel: "boot/vmlinuz", root_digest: bytes.from_text(id).sha256().hex()}
}

proc main(operation: Str, root: Path) [fs, process, time, error] {
  guard root == p"/home/probe/ssh-proof" and "LAPUTA_ACTIVATION_SSH_FIXTURE=1" in p"/proc/cmdline".read_text()?.trim().split(" ") else { fail "activation drill requires its disposable guest" }
  let state = fp"{root}/activation"
  if operation == "prepare" {
    state.mkdir()?
    let kernel = fp"{state}/kernel"
    let disk = fp"{state}/disk"
    kernel.write("kernel")?
    disk.write("disk")?
    let a = activation.activation_publish_image(state, receipt("a"), kernel, disk, activation.ACTIVATION_STATE_FORMAT)?
    let b = activation.activation_publish_image(state, receipt("b"), kernel, disk, activation.ACTIVATION_STATE_FORMAT)?
    activation.activation_install(state, receipt("a"), {revision: 1, images: [a, b]})?
  } else if operation == "stage" {
    activation.activation_stage(state, receipt("b"))?
    fp"{root}/committed".write(f"{process.current_pid()?}")?
    for _ in range(300) {
      if fp"{root}/release".exists()? { print "acknowledged"; return }
      time.sleep(100ms)?
    }
    fail "release timed out"
  } else if operation == "inspect" {
    let record = activation.activation_status(state)?
    assert record.current == receipt("a") and record.fallback == receipt("a") and record.pending == receipt("b")
    assert record.boot_attempts == 0 and record.boot_serial == 0 and record.last_operation == "staged"
    let _ = activation.activation_verify_image(state, receipt("a"))?
    let _ = activation.activation_verify_image(state, receipt("b"))?
    match activation.activation_stage(state, receipt("b")) {
      Ok(_) => { fail "duplicate staging succeeded" },
      Err(failure) => { assert "a generation is already pending" in failure.message },
    }
    let after = activation.activation_status(state)?
    assert after == record
    let selected = launcher.launcher_select(state)?
    assert selected.id == "b" and selected.boot_serial == 1
    let selected_record = activation.activation_status(state)?
    assert selected_record.pending == receipt("b") and selected_record.boot_attempts == 1
  } else {
    fail "unknown operation"
  }
  print "acknowledged"
}
main(@args)?
