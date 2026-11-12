use pm.generation
use seed.self_hosting_verify as verify
use system.activation

proc main(operation: Str, output: Path, bundle: Path, selected_kernel: Path, tools_image: Str) [fs, process, env, time, error] -> Result[Unit, Error] {
  let state = fp"{output}/generations"
  let receipt = generation.read_generation_receipt_file(fp"{bundle}/generation.json")?
  guard receipt.profile.name == "qemu-self-hosting" else { fail "local self-hosting admission requires the development profile" }
  let identity = receipt.generation_sha256
  let candidate = activation.GenerationReceipt(id: identity, kernel: "boot/vmlinuz", root_digest: identity)
  verify.self_hosting_verify_bundle(bundle, identity, selected_kernel, tools_image)?
  if operation == "install" {
    guard ! fp"{state}/{activation.ACTIVATION_RECORD_NAME}".exists() else { fail "self-hosting activation is already installed" }
    state.mkdir()?
    let admitted = activation.activation_publish_image(state, candidate, fp"{bundle}/vmlinuz", fp"{bundle}/disk.img", activation.ACTIVATION_STATE_FORMAT)?
    activation.activation_install(state, candidate, {revision: 1, images: [admitted]})?
  } else if operation == "stage" {
    let before = activation.activation_status(state)?
    guard before.pending == null and before.current != candidate else { fail "self-hosting candidate cannot be staged" }
    let admitted = activation.activation_publish_image(state, candidate, fp"{bundle}/vmlinuz", fp"{bundle}/disk.img", activation.ACTIVATION_STATE_FORMAT)?
    activation.activation_update_policy(state, {revision: before.admission_policy.revision + 1, images: before.admission_policy.images + [admitted]})?
    activation.activation_stage(state, candidate)?
  } else if operation == "restage" {
    activation.activation_stage(state, candidate)?
  } else if operation == "confirm" {
    activation.activation_confirm_health(state, identity)?
  } else {
    fail "expected install, stage, restage, or confirm"
  }
  print json.encode(activation.activation_status(state)?)?
}

main(@args)?
