use system.activation

proc receipt(id: Str) -> activation.GenerationReceipt {
  {id, kernel: "boot/vmlinuz", root_digest: bytes.from_text(id).sha256().hex()}
}

proc main(operation: Str, directory: Str) {
  let state = Path(directory)
  if operation == "prepare" {
    state.mkdir()
    let kernel = fp"{state}/kernel"
    let disk = fp"{state}/disk"
    kernel.write("kernel")
    disk.write("disk")
    for id in ["a", "b", "c"] {
      let _ = activation.activation_publish_image(state, receipt(id), kernel, disk, activation.ACTIVATION_STATE_FORMAT)?
    }
    activation.activation_install(state, receipt("a"), {revision: 1, images: [activation.ImageAdmission(generation: receipt(id), state_format: activation.ACTIVATION_STATE_FORMAT, kernel_sha256: bytes.from_text("kernel").sha256().hex(), disk_sha256: bytes.from_text("disk").sha256().hex()) for id in ["a", "b", "c"]]})
  } else if operation == "b" or operation == "c" {
    activation.activation_stage(state, receipt(operation))
  } else if operation == "select" {
    let _ = activation.activation_begin_boot(state)?
  } else if operation == "confirm" {
    activation.activation_confirm_health(state, "b")
  } else if operation == "collect" {
    let _ = activation.activation_collect_images(state)?
  } else if operation == "revoke" {
    activation.activation_update_policy(state, {revision: 2, images: []})
  } else if operation == "status" {
    let record = activation.activation_status(state)?
    let _ = activation.activation_verify_image(state, record.current)?
    let _ = activation.activation_verify_image(state, record.fallback)?
    if record.pending != null {
      let _ = activation.activation_verify_image(state, record.pending)?
    }
  } else {
    fail "unknown recovery operation"
  }
  print "acknowledged"
}
