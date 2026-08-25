##! Behavior coverage for durable profile build output locations.
use laputa.build as build

proc test_profile_outputs_have_one_exact_generation_and_image_layout() [error] {
  let outputs = build.outputs(p"target/laputa/qemu-dwl-foot")
  test.eq(outputs.build_plan, p"target/laputa/qemu-dwl-foot/build-plan.json")?
  test.eq(outputs.generation_plan, p"target/laputa/qemu-dwl-foot/generation-plan.json")?
  test.eq(outputs.generation, p"target/laputa/qemu-dwl-foot/generation.json")?
  test.eq(outputs.rootfs, p"target/laputa/qemu-dwl-foot/rootfs.ext4")?
  test.eq(outputs.disk, p"target/laputa/qemu-dwl-foot/disk.img")?
  test.eq(outputs.kernel, p"target/laputa/qemu-dwl-foot/vmlinuz")?
}
