##! Profile-output paths and the typed package-plan Docker adapter.
use laputa.docker as docker
use laputa.image as image
use laputa.types as types

## The durable host output paths owned by one system profile.
export type ProfileOutputs = {
  root: Path,
  builds: Path,
  current: Path,
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
    builds: fp"${root}/builds",
    current: fp"${root}/current",
    build_plan: fp"${root}/build-plan.json",
    generation_plan: fp"${root}/generation-plan.json",
    generation: fp"${root}/current/generation.json",
    rootfs: fp"${root}/current/rootfs.ext4",
    disk: fp"${root}/current/disk.img",
    kernel: fp"${root}/current/vmlinuz",
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

## Generate the profile's exact BuildPlan and its runtime-only GenerationPlan through the native PM container.
export proc plan_profile(value: docker.DockerConfig, profile: types.SystemProfile) [fs, process, error] -> Result[ProfileOutputs] {
  let result = outputs(value.output_root)
  docker.docker_plan(value, profile)?

  if ! fs.exists(result.build_plan)? {
    return Err(types.LaputaError.Docker(f"PM plan command did not write ${result.build_plan}"))
  }

  docker.docker_generation_plan(value, profile)?

  if ! fs.exists(result.generation_plan)? {
    return Err(types.LaputaError.Docker(f"PM generation plan command did not write ${result.generation_plan}"))
  }

  result
}

## Execute the already-explicit package plan, compose its immutable generation, and atomically publish disk outputs.
export proc build_profile(value: docker.DockerConfig, profile: types.SystemProfile, jobs: Int) [fs, process, error] -> Result[ProfileOutputs] {
  let result = plan_profile(value, profile)?
  docker.docker_profile_build(value, profile, jobs, result.build_log)?

  if ! fs.exists(result.current)? or fs.metadata(result.current)?.kind != "symlink" {
    return Err(types.LaputaError.Docker(f"profile build did not atomically select ${result.current}"))
  }

  for path_value in [result.generation, result.rootfs, result.disk, result.kernel] {
    if ! fs.exists(path_value)? or fs.metadata(path_value)?.size <= 0 {
      return Err(types.LaputaError.Docker(f"profile build did not publish ${path_value}"))
    }
  }

  image.verify_disk(result.disk, fs.metadata(result.rootfs)?.size)?
  result
}
