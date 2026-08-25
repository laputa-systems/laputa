##! Explicit command parsing for the single qemu-dwl-foot Laputa profile.
use laputa.build as build
use laputa.docker as docker
use laputa.profile as profile
use laputa.qemu as qemu
use laputa.types as types

type CliArgs = {command: Str, profile_name: Str, jobs: Int}

## Render concise help for the final public Laputa command surface.
export pure usage() -> Str {
  """usage: laputa <plan|build|test|boot|clean> qemu-dwl-foot [--jobs N]

Build and test the one supported aarch64-linux-musl reference system.
"""
}

## Decode command arguments without filesystem-dependent interpretation.
export proc parse(argv: List[Str]) [error] -> Result[CliArgs] {
  if argv.len() == 0 or argv[0] == "--help" or argv[0] == "-h" {
    return Err(types.LaputaError.Usage(usage()))
  }

  let command = argv[0]
  if command != "plan" and command != "build" and command != "test" and command != "boot" and command != "clean" {
    return Err(types.LaputaError.Usage(f"unknown laputa command ${command}\n\n${usage()}"))
  }

  if argv.len() < 2 {
    return Err(types.LaputaError.Usage(f"laputa ${command} requires a profile name\n\n${usage()}"))
  }

  let profile_name = argv[1]
  var jobs = 1
  var index = 2

  while index < argv.len() {
    let token = argv[index]

    if token == "--jobs" or token == "-j" {
      if command != "build" or index + 1 >= argv.len() {
        return Err(types.LaputaError.Usage(f"invalid ${token} for laputa ${command}"))
      }

      jobs = argv[index + 1].parse_int()?
      if jobs <= 0 {
        return Err(types.LaputaError.Usage("--jobs must be positive"))
      }

      index += 2
      continue
    }

    return Err(types.LaputaError.Usage(f"unexpected argument ${token}\n\n${usage()}"))
  }

  {command, profile_name, jobs}
}

## Run the profile command through typed profile validation and Docker configuration.
export proc dispatch(argv: List[Str]) [fs, process, env, time, error] {
  let parsed = parse(argv)?
  let root = fs.cwd()?
  let value = profile.load(parsed.profile_name, fp"${root}/profiles")?
  let docker_config = docker.build_config(root, value.name)?

  if parsed.command == "clean" {
    build.clean(docker_config)?
    print f"laputa clean ${value.name}: ok"
    return
  }

  if parsed.command == "plan" {
    print f"profile ${value.name} ${profile.digest(value)?}"
    build.unavailable("plan")?
    return
  }

  let outputs = build.outputs(docker_config.output_root)
  if parsed.command == "test" {
    qemu.run_test(qemu.qemu_config(root)?, value, outputs)?
    return
  }

  if parsed.command == "boot" {
    qemu.boot(qemu.qemu_config(root)?, value, outputs)?
    return
  }

  let _ = parsed.jobs
  build.unavailable(parsed.command)?
}
