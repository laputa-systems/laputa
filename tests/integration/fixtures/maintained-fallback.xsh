##! Maintained-guest drill fixture: set up and select activation generations
##! for the host-driven QEMU fallback drill. The harness provisions the state
##! disk and launches QEMU; this fixture only mutates the activation record
##! under the writer lock and prints JSON the harness consumes.
use system.activation
use system.build
use system.launcher
use system.qemu
use system.types
use profiles.qemu-maintained as maintained

proc receipt(id: Str) -> activation.GenerationReceipt {
  {id, kernel: "boot/vmlinuz", root_digest: bytes.from_text(id).sha256().hex()}
}

type Bundle = {kernel: Path, disk: Path}

proc current_bundle() -> Result[Bundle] {
  let outputs = build.outputs(p"target/laputa/qemu-maintained")
  guard fp"{outputs.kernel}".exists() and fp"{outputs.disk}".exists() else {
    fail "maintained image is missing; run laputa build qemu-maintained first"
  }
  {kernel: outputs.kernel, disk: outputs.disk}
}

proc main(operation: Str, directory: Str = "") {
  let state = Path(directory)
  if operation == "setup" {
    let bundle = current_bundle()?
    let admitted_a = activation.activation_publish_image(state, receipt("a"), bundle.kernel, bundle.disk, activation.ACTIVATION_STATE_FORMAT)?
    let admitted_b = activation.activation_publish_image(state, receipt("b"), bundle.kernel, bundle.disk, activation.ACTIVATION_STATE_FORMAT)?
    activation.activation_install(state, receipt("a"), {revision: 1, images: [admitted_a, admitted_b]})
    activation.activation_stage(state, receipt("b"))
    print "acknowledged"
  } else if operation == "argv" {
    let target = qemu.host_qemu_target()?
    let config = qemu.qemu_config(target)?
    let profile = maintained.profile
    let outputs = build.outputs(p"target/laputa/qemu-maintained")
    let argv = qemu.boot_command_argv(config, profile, outputs, types.Test, state)?
    let encoded = json.encode({argv})?
    print $encoded
  } else if operation == "argv-plain" {
    let target = qemu.host_qemu_target()?
    let config = qemu.qemu_config(target)?
    let profile = maintained.profile
    let outputs = build.outputs(p"target/laputa/qemu-maintained")
    let argv = qemu.boot_command_argv(config, profile, outputs, types.Test, null)?
    let encoded = json.encode({argv})?
    print $encoded
  } else if operation == "status" {
    let record = activation.activation_status(state)?
    let pending = if record.pending == null { null } else { record.pending.id }
    let encoded = json.encode({current: record.current.id, pending: pending, attempts: record.boot_attempts, serial: record.boot_serial, last: record.last_operation})?
    print $encoded
  } else {
    fail "unknown drill operation"
  }
}
