##! Behavior coverage for durable profile build output locations.
use system.build

test test_profile_outputs_have_one_exact_generation_and_image_layout [error] {
  let outputs = build.outputs(p"target/laputa/qemu-tinyland-ghostty")
  assert outputs.builds == p"target/laputa/qemu-tinyland-ghostty/builds"
  assert outputs.current == p"target/laputa/qemu-tinyland-ghostty/current"
  assert outputs.build_plan == p"target/laputa/qemu-tinyland-ghostty/build-plan.json"
  assert outputs.generation_plan == p"target/laputa/qemu-tinyland-ghostty/generation-plan.json"
  assert outputs.generation == p"target/laputa/qemu-tinyland-ghostty/current/generation.json"
  assert outputs.rootfs == p"target/laputa/qemu-tinyland-ghostty/current/rootfs.ext4"
  assert outputs.disk == p"target/laputa/qemu-tinyland-ghostty/current/disk.img"
  assert outputs.kernel == p"target/laputa/qemu-tinyland-ghostty/current/vmlinuz"
}

test test_profile_build_crosses_into_pm_with_process_argv_not_a_request_dto [fs, error] {
  let build_source = p"system/build.xsh".read_text()?
  let container_source = p"system/container_build.xsh".read_text()?

  assert ! ("ProfileBuildRequestDto" in build_source)
  assert ! (".build-request.json" in build_source)
  assert ! ("ContainerProfileBuildRequest" in container_source)
  assert ! (".build-request.json" in container_source)
  assert "process.command_argv" in container_source
  assert "/src/laputa/pm.xsh" in container_source
}
