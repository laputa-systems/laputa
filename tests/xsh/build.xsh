##! Behavior coverage for durable profile build output locations.
use laputa.build as build

proc test_profile_outputs_have_one_exact_generation_and_image_layout() [error] {
  let outputs = build.outputs(p"target/laputa/qemu-dwl-foot")
  test.eq(outputs.builds, p"target/laputa/qemu-dwl-foot/builds")?
  test.eq(outputs.current, p"target/laputa/qemu-dwl-foot/current")?
  test.eq(outputs.build_plan, p"target/laputa/qemu-dwl-foot/build-plan.json")?
  test.eq(outputs.generation_plan, p"target/laputa/qemu-dwl-foot/generation-plan.json")?
  test.eq(outputs.generation, p"target/laputa/qemu-dwl-foot/current/generation.json")?
  test.eq(outputs.rootfs, p"target/laputa/qemu-dwl-foot/current/rootfs.ext4")?
  test.eq(outputs.disk, p"target/laputa/qemu-dwl-foot/current/disk.img")?
  test.eq(outputs.kernel, p"target/laputa/qemu-dwl-foot/current/vmlinuz")?
}

proc test_profile_build_crosses_into_pm_with_process_argv_not_a_request_dto() [fs, error] {
  let build_source = fs.read_text(p"laputa/build.xsh")?
  let container_source = fs.read_text(p"laputa/container_build.xsh")?

  test.ok(! ("ProfileBuildRequestDto" in build_source))?
  test.ok(! (".build-request.json" in build_source))?
  test.ok(! ("ContainerProfileBuildRequest" in container_source))?
  test.ok(! (".build-request.json" in container_source))?
  test.ok("process.command_argv" in container_source)?
  test.ok("/src/packages/pm.xsh" in container_source)?
}
