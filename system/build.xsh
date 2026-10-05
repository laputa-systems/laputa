##! Profile-output paths and the typed package-plan Docker adapter.
use system.docker
use system.image
use system.types

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

# A Unix socket path must fit sockaddr_un's 108 bytes, and a checkout's
# target/ can sit deeper than that (a git worktree, say). The QMP socket lives
# in /tmp, named by the output root so two checkouts never share one.
## The QMP control socket for the profile whose outputs live in `root`.
export pure qmp_socket_path(root: Path) -> Path {
  fp"/tmp/laputa-qmp-{root.bytes().sha256().hex()[..16]}.sock"
}

## Derive every profile output path from one profile-owned root directory.
export pure outputs(root: Path) -> ProfileOutputs {
  {
    root,
    builds: fp"{root}/builds",
    current: fp"{root}/current",
    build_plan: fp"{root}/build-plan.json",
    generation_plan: fp"{root}/generation-plan.json",
    generation: fp"{root}/current/generation.json",
    rootfs: fp"{root}/current/rootfs.ext4",
    disk: fp"{root}/current/disk.img",
    kernel: fp"{root}/current/vmlinuz",
    build_log: fp"{root}/build.log",
    console_log: fp"{root}/console.log",
    qemu_log: fp"{root}/qemu.log",
    qmp_socket: qmp_socket_path(root),
    screenshot: fp"{root}/screenshot.ppm",
  }
}

## Remove only generated outputs, preserving the immutable artifact-store volume.
export proc clean(output_root: Path) [fs, error] {
  output_root.remove(missing_ok: true)
}

## Generate the profile's exact BuildPlan and its runtime-only GenerationPlan through the native PM container.
export proc plan_system_profile(
  value: docker.DockerConfig,
  profile: types.SystemProfile,
) [fs, process, error] -> Result[ProfileOutputs, Error] {
  let result = outputs(value.output_root)
  docker.docker_plan(value, profile)

  if ! result.build_plan.exists()? {
    return Err(types.LaputaError.Docker(f"PM plan command did not write {result.build_plan}"))
  }

  docker.docker_generation_plan(value, profile)

  if ! result.generation_plan.exists()? {
    return Err(types.LaputaError.Docker(f"PM generation plan command did not write {result.generation_plan}"))
  }

  result
}

## Execute the already-explicit package plan, compose its immutable generation, and atomically publish disk outputs.
export proc build_profile(
  value: docker.DockerConfig,
  profile: types.SystemProfile,
  jobs: Int,
) [fs, process, error] -> Result[ProfileOutputs, Error] {
  let result = plan_system_profile(value, profile)?
  docker.docker_profile_build(value, profile, jobs, result.build_log)

  if ! result.current.exists()? or ! result.current.is_symlink()? {
    return Err(types.LaputaError.Docker(f"profile build did not atomically select {result.current}"))
  }

  for path_value in [result.generation, result.rootfs, result.disk, result.kernel] {
    if ! path_value.exists()? or path_value.metadata()?.size <= 0 {
      return Err(types.LaputaError.Docker(f"profile build did not publish {path_value}"))
    }
  }

  image.verify_disk(result.disk, result.rootfs.metadata()?.size)
  result
}
