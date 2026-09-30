##! Behavior coverage for durable profile build output locations.
use laputa.build as build

test test_profile_outputs_have_one_exact_generation_and_image_layout [error] {
  let outputs = build.outputs(p"target/laputa/qemu-dwl-foot")
  outputs.builds == p"target/laputa/qemu-dwl-foot/builds"
  outputs.current == p"target/laputa/qemu-dwl-foot/current"
  outputs.build_plan == p"target/laputa/qemu-dwl-foot/build-plan.json"
  outputs.generation_plan == p"target/laputa/qemu-dwl-foot/generation-plan.json"
  outputs.generation == p"target/laputa/qemu-dwl-foot/current/generation.json"
  outputs.rootfs == p"target/laputa/qemu-dwl-foot/current/rootfs.ext4"
  outputs.disk == p"target/laputa/qemu-dwl-foot/current/disk.img"
  outputs.kernel == p"target/laputa/qemu-dwl-foot/current/vmlinuz"
}

test test_profile_build_crosses_into_pm_with_process_argv_not_a_request_dto [fs, error] {
  let build_source = fs.read_text(p"laputa/build.xsh")?
  let container_source = fs.read_text(p"laputa/container_build.xsh")?

  ! ("ProfileBuildRequestDto" in build_source)
  ! (".build-request.json" in build_source)
  ! ("ContainerProfileBuildRequest" in container_source)
  ! (".build-request.json" in container_source)
  "process.command_argv" in container_source
  "/src/packages/pm.xsh" in container_source
}
