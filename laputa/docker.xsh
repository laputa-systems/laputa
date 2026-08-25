##! Native Linux arm64 Docker command construction for Laputa profile builds.
use laputa.types as types

## The fixed host paths and named volumes mounted into the profile build container.
export type DockerConfig = {
  docker: Path,
  packages_root: Path,
  laputa_root: Path,
  xsh_root: Path,
  output_root: Path,
  artifact_volume: Str,
  source_volume: Str,
  image: Str,
}

proc env_value(name: Str, fallback: Str) [env] -> Str {
  let value = (env.get(name) ?? "").trim()
  if value == "" {
    return fallback
  }

  return value
}

## Resolve the allowed Docker configuration surface from the host environment.
export proc config(laputa_root: Path, profile_name: Str) [fs, process, env, error] -> Result[DockerConfig] {
  let packages_root = fp"${env_value("LAPUTA_PACKAGES_ROOT", fp"${laputa_root.parent}/packages".display())}"
  let xsh_root = fp"${env_value("XSH_SOURCE_ROOT", fp"${laputa_root.parent}/xsh".display())}"
  let docker = fp"${env_value("DOCKER", "docker")}"
  let output_root = fp"${laputa_root}/target/laputa/${profile_name}"

  if ! fs.exists(packages_root)? {
    return Err(types.LaputaError.Docker(f"package checkout does not exist: ${packages_root}"))
  }

  if ! fs.exists(xsh_root)? or ! fs.exists(fp"${xsh_root}/core")? {
    return Err(types.LaputaError.Docker(f"XSH source checkout with core/ does not exist: ${xsh_root}"))
  }

  if ! fs.exists(docker)? {
    let _ = process.which(docker.display())?
  }

  {
    docker,
    packages_root,
    laputa_root,
    xsh_root,
    output_root,
    artifact_volume: "laputa-artifacts-aarch64-v1",
    source_volume: "laputa-sources-aarch64-v1",
    image: "laputa-package-tools",
  }
}

## Construct an exact native-arm64 Docker invocation for an inner PM command.
export pure command_argv(value: DockerConfig, inner_argv: List[Str]) -> List[Str] {
  [
    value.docker.display(),
    "run",
    "--rm",
    "--platform",
    "linux/arm64",
    "--mount",
    f"type=bind,src=${value.packages_root.display()},dst=/src/packages,readonly",
    "--mount",
    f"type=bind,src=${value.laputa_root.display()},dst=/src/laputa,readonly",
    "--mount",
    f"type=bind,src=${value.xsh_root.display()}/core,dst=/usr/lib/xsh/core,readonly",
    "--mount",
    f"type=bind,src=${value.output_root.display()},dst=/output",
    "--mount",
    f"type=volume,src=${value.artifact_volume},dst=/artifacts",
    "--mount",
    f"type=volume,src=${value.source_volume},dst=/sources",
    "--workdir",
    "/src/packages",
    "--env",
    "XSH_MODULE_PATH=/src/packages",
    "--env",
    "PATH=/bin:/usr/bin",
    value.image,
  ].extend(inner_argv)
}

## Return the structured host command that executes an exact Docker invocation.
export proc command(value: DockerConfig, inner_argv: List[Str]) [fs, process, error] -> Result[Command] {
  fs.mkdir(value.output_root)?
  process.command_argv(value.docker, command_argv(value, inner_argv), value.laputa_root)
}

## Reject Docker images that are not a native arm64 execution substrate.
export proc verify_arm64_image(value: DockerConfig) [process, error] {
  let output = run.text $value.docker image inspect --format "{{.Architecture}}" $value.image ?
  let architecture = output.trim()

  if architecture != "arm64" {
    return Err(types.LaputaError.Docker(f"${value.image} reports ${architecture}; native arm64 is required"))
  }
}
