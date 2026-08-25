##! Profile-output paths and the typed package-plan Docker adapter.
use laputa.docker as docker
use laputa.image as image
use laputa.profile as system_profile
use laputa.types as types

type ProfileBuildRequestDto = {
  format: Str,
  name: Str,
  runtime_roots: List[Str],
  kernel_package: Str,
  kernel_path: Str,
  forbidden_packages: List[Str],
  forbidden_sonames: List[Str],
}

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

# The request is an implementation input for the mounted native container, not a public build output.
pure profile_build_request_path(root: Path) -> Path {
  fp"${root}/.build-request.json"
}

# Serialize only profile data required by the native PM executor, after its host-side typed validation.
# This DTO keeps `container_build.xsh` free of the Laputa profile module so it can coexist with PM's
# independently typed target union in XSH's process-wide user-module namespace.
proc write_profile_build_request(path_value: Path, value: types.SystemProfile) [fs, error] {
  system_profile.validate(value)?
  let request: ProfileBuildRequestDto = {
    format: "laputa-profile-build-request-1",
    name: value.name,
    runtime_roots: value.package_roots,
    kernel_package: value.kernel_package,
    kernel_path: value.kernel_path.display(),
    forbidden_packages: value.forbidden_packages,
    forbidden_sonames: value.forbidden_sonames,
  }
  fs.mkdir(path_value.parent)?
  fs.write_atomic(
    path_value,
    json.encode(request)? + "\n",
  )?
}

## Remove only generated outputs, preserving the immutable artifact-store volume.
export proc clean(output_root: Path) [fs, error] {
  fs.remove(output_root, missing_ok: true)?
}

## Generate the profile's exact BuildPlan and its runtime-only GenerationPlan through the native PM container.
export proc plan_profile(value: docker.DockerConfig, profile: types.SystemProfile) [fs, process, error] -> Result[ProfileOutputs] {
  let result = outputs(value.output_root)
  write_profile_build_request(profile_build_request_path(result.root), profile)?
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

  for path_value in [result.generation, result.rootfs, result.disk, result.kernel] {
    if ! fs.exists(path_value)? or fs.metadata(path_value)?.size <= 0 {
      return Err(types.LaputaError.Docker(f"profile build did not publish ${path_value}"))
    }
  }

  image.verify_disk(result.disk, fs.metadata(result.rootfs)?.size)?
  result
}
