##! Profile-output paths and the typed package-plan Docker adapter.
use laputa.docker as docker
use laputa.types as types

## The durable host output paths owned by one system profile.
export type ProfileOutputs = {
  root: Path,
  build_plan: Path,
  generation_plan: Path,
  generation: Path,
  rootfs: Path,
  disk: Path,
  kernel: Path,
  build_log: Path,
  console_log: Path,
  qemu_log: Path,
  qmp_socket: Path,
  screenshot: Path,
}

## Derive every profile output path from one profile-owned root directory.
export pure outputs(root: Path) -> ProfileOutputs {
  {
    root,
    build_plan: fp"${root}/build-plan.json",
    generation_plan: fp"${root}/generation-plan.json",
    generation: fp"${root}/generation.json",
    rootfs: fp"${root}/rootfs.ext4",
    disk: fp"${root}/disk.img",
    kernel: fp"${root}/vmlinuz",
    build_log: fp"${root}/build.log",
    console_log: fp"${root}/console.log",
    qemu_log: fp"${root}/qemu.log",
    qmp_socket: fp"${root}/qmp.sock",
    screenshot: fp"${root}/screenshot.ppm",
  }
}

## Remove only generated outputs, preserving the immutable artifact-store volume.
export proc clean(output_root: Path) [fs, error] {
  fs.remove(output_root, missing_ok: true)?
}

## Generate the profile's exact BuildPlan through PM's explicit Docker CLI, without beginning Task 13 artifact execution or image construction.
export proc plan_profile(value: docker.DockerConfig, profile: types.SystemProfile) [fs, process, error] -> Result[ProfileOutputs] {
  let result = outputs(value.output_root)
  docker.docker_plan(value, profile)?

  if ! fs.exists(result.build_plan)? {
    return Err(types.LaputaError.Docker(f"PM plan command did not write ${result.build_plan}"))
  }

  result
}

## Explain that package planning awaits the typed package-manager BuildPlan API.
export proc unavailable(action: Str) [error] {
  return Err(types.LaputaError.Incomplete(f"laputa ${action} requires the typed PM BuildPlan and generation APIs"))
}
