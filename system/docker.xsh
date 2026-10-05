##! Native Linux Docker command construction for Laputa profile builds.
use seed.images
use seed.world
use seed.xsh_seed
use system.types

## The fixed host paths mounted into the profile build container.
## `laputa_root` is the monorepo checkout: PM, recipes, profiles, and system modules.
## `seed` is the verified local XSH seed; `artifact_root` is the PM artifact store under `.out/`.
## `arch` is the PM target architecture, built natively on `platform`, the host's Docker platform;
## the seed, store, and image all match it.
export type DockerConfig = {
  docker: Path,
  arch: Str,
  platform: Str,
  laputa_root: Path,
  seed: Path,
  output_root: Path,
  artifact_root: Path,
  image: Str,
  repo_url: Str,
  owner: world.WorldOwner,
}

proc env_value(name: Str, fallback: Str) -> Str {
  let value = (env.get(name) ?? "").trim()
  return fallback when value == ""

  value
}

## The bind-mounted PM artifact store for one architecture. A bind mount keeps
## every artifact under `.out/`, which `make clean` owns; artifacts are large
## sequential files, where bind-mount I/O matches a named volume.
export pure artifact_store_root(laputa_root: Path, arch: Str) -> Path {
  fp"{laputa_root}/.out/artifacts/{arch}"
}

## Resolve the allowed Docker configuration surface for building `profile_name` natively for `arch`.
export proc build_config(
  laputa_root: Path,
  profile_name: Str,
  arch: Str,
) [fs, process, env, error] -> Result[DockerConfig, Error] {
  let docker = fp"{env_value("DOCKER", "docker")}"
  let output_root = fp"{laputa_root}/target/laputa/{profile_name}"

  if ! docker.exists() {
    let _ = process.which(docker)?
  }

  let seed_arch = xsh_seed.xsh_seed_arch(arch)?
  let seed = xsh_seed.xsh_seed_require(laputa_root, arch)?
  let artifact_root = artifact_store_root(laputa_root, arch)
  artifact_root.mkdir()
  world.world_kbuild_cache(laputa_root).mkdir()

  let image = images.ensure_package_tools(docker, laputa_root, seed_arch)?
  DockerConfig(
    docker:,
    arch:,
    platform: seed_arch.docker_platform,
    laputa_root:,
    seed:,
    output_root:,
    artifact_root:,
    image:,
    repo_url: env_value("LAPUTA_REPO_URL", ""),
    owner: {uid: unix.id()?.uid, gid: unix.id()?.gid},
  )
}

## Construct an exact native-platform Docker invocation for an inner PM command.
export pure docker_command_argv(value: DockerConfig, inner_argv: List[Str]) -> List[Str] {
  # PM modules must resolve from the mounted checkout's source root.
  # The finished rootfs may contain /usr/lib/pm, but it must never share the
  # interpreter process used for planning, execution, or generation.
  # Bootstrap recipes use the container's compiler before its replacement artifact exists.
  var argv = [
    value.docker.display(),
    "run",
    "--rm",
    "--platform",
    value.platform,
    "--mount",
    f"type=bind,src={value.laputa_root},dst=/src/laputa,readonly",
    @xsh_seed.xsh_seed_mount_argv(value.seed),
    "--mount",
    f"type=bind,src={value.output_root},dst=/output",
    "--mount",
    f"type=bind,src={value.artifact_root},dst=/artifacts",
    @world.world_kbuild_cache_mount_argv(value.laputa_root),
    "--workdir",
    "/src/laputa",
    "--env",
    "XSH_MODULE_PATH=/src/laputa",
    "--env",
    "PATH=/bin:/usr/lib/xsh/core:/usr/bin",
    "--env",
    "XSH_PM_BOOTSTRAP_LLVM_ROOT=/usr/lib/llvm23",
  ]

  if value.repo_url != "" {
    argv += ["--env", f"XSH_PM_REPO={value.repo_url}"]
  }

  argv.push(value.image).extend(world.world_owned_argv(value.owner, inner_argv))
}

## Construct the sole PM planning command used by a SystemProfile, with only profile-declared direct roots and its separate kernel package.
export pure docker_pm_plan_argv(profile: types.SystemProfile, arch: Str) -> List[Str] {
  # The mounted checkout owns this PM invocation.  Mixing the image's pm.xsh
  # entrypoint with checkout modules loads pm.types twice under the published
  # runner's shared user-module namespace.
  var argv = ["/bin/xsh", "/src/laputa/pm.xsh", "--", "repo", "plan", "--repo", "/src/laputa"]

  for package_name in profile.package_roots {
    argv += ["--root", package_name]
  }

  argv += ["--root", profile.kernel_package, "--target", f"{arch}-linux-musl", "--output", "/output/build-plan.json"]
  argv
}

## Construct the complete native-platform Docker invocation for a profile BuildPlan without encoding a second package closure.
export pure docker_plan_command_argv(value: DockerConfig, profile: types.SystemProfile) -> List[Str] {
  docker_command_argv(value, docker_pm_plan_argv(profile, value.arch))
}

## Construct the typed in-container generation-plan projection without executing or composing artifacts.
export pure docker_generation_plan_argv(profile: types.SystemProfile) -> List[Str] {
  [
    "/bin/xsh",
    "/src/laputa/system/container_build.xsh",
    "--",
    "plan",
    profile.name,
    "1",
  ]
}

## Construct the typed in-container artifact execution, generation composition, kernel extraction, ext4, and GPT workflow.
export pure docker_profile_build_argv(profile: types.SystemProfile, jobs: Int) -> List[Str] {
  [
    "/bin/xsh",
    "/src/laputa/system/container_build.xsh",
    "--",
    "build",
    profile.name,
    f"{jobs}",
  ]
}

## Return the structured host command that executes an exact Docker invocation.
export proc command(value: DockerConfig, inner_argv: List[Str]) [fs, process, error] -> Result[Command, Error] {
  value.output_root.mkdir()
  process.command_argv(value.docker, docker_command_argv(value, inner_argv), value.laputa_root)
}

## Reject an image whose architecture is not the configured native platform's.
export proc require_image_architecture(platform: Str, architecture: Str) [error] {
  guard f"linux/{architecture}" == platform else {
    return Err(types.LaputaError.Docker(f"Docker runner reports {architecture}; native {platform} is required"))
  }
}

## Reject Docker images that are not the native execution substrate.
export proc verify_image_architecture(value: DockerConfig) [process, error] {
  let output = run.text $value.docker image inspect --format "{{.Architecture}}" $value.image
  require_image_architecture(value.platform, output.trim())
}

## Run a profile-owned Docker command only after the runner image proves it is native.
export proc docker_run(value: DockerConfig, inner_argv: List[Str]) [fs, process, error] {
  verify_image_architecture(value)
  let status = process.run(command(value, inner_argv)?)?

  if ! status.ok {
    return Err(types.LaputaError.Docker(f"Docker command failed for {value.image}"))
  }
}

## Run a profile build while atomically replacing its log only after Docker exits successfully.
export proc docker_run_logged(value: DockerConfig, inner_argv: List[Str], log: Path) [fs, process, error] {
  verify_image_architecture(value)
  log.parent.mkdir()
  atomically replace log as temporary {
    let status = process.run(
      process.command_argv(value.docker, docker_command_argv(value, inner_argv), value.laputa_root, stdout: temporary),
    )?

    if ! status.ok {
      return Err(types.LaputaError.Docker(f"Docker command failed for {value.image}"))
    }

    fs.fsync(temporary)
  }
}

## Run the sole profile PM-plan adapter through the checked native runner.
export proc docker_plan(value: DockerConfig, profile: types.SystemProfile) [fs, process, error] {
  docker_run(value, docker_pm_plan_argv(profile, value.arch))
}

## Project one saved BuildPlan to its typed generation plan through the native runner.
export proc docker_generation_plan(value: DockerConfig, profile: types.SystemProfile) [fs, process, error] {
  docker_run(value, docker_generation_plan_argv(profile))
}

## Build one complete profile image through the native runner and keep its build log transactional.
export proc docker_profile_build(
  value: DockerConfig,
  profile: types.SystemProfile,
  jobs: Int,
  log: Path,
) [fs, process, error] {
  guard jobs >= 1 else {
    return Err(types.LaputaError.Usage("laputa build jobs must be positive"))
  }

  docker_run_logged(value, docker_profile_build_argv(profile, jobs), log)
}
