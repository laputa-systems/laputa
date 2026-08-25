##! Explicit command parsing for the single qemu-dwl-foot Laputa profile.
use laputa.build as build
use laputa.docker as docker
use laputa.profile as profile
use laputa.qemu as qemu
use laputa.types as types

## The closed public Laputa command surface; all execution choices are explicit command data.
export type LaputaCommand = LaputaPlan | LaputaBuild | LaputaTest | LaputaBoot | LaputaClean

## The parsed command and its profile-owned execution parameters.
export type CliArgs = {command: LaputaCommand, profile_name: Str, jobs: Int}

## Render a parsed command at the user-facing boundary.
export pure command_text(command: LaputaCommand) -> Str {
  match command {
    LaputaPlan => "plan"
    LaputaBuild => "build"
    LaputaTest => "test"
    LaputaBoot => "boot"
    LaputaClean => "clean"
  }
}

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

  if argv[0] != "plan" and argv[0] != "build" and argv[0] != "test" and argv[0] != "boot" and argv[0] != "clean" {
    return Err(types.LaputaError.Usage(f"unknown laputa command ${argv[0]}\n\n${usage()}"))
  }

  var command: LaputaCommand = LaputaPlan
  if argv[0] == "build" {
    command = LaputaBuild
  } else if argv[0] == "test" {
    command = LaputaTest
  } else if argv[0] == "boot" {
    command = LaputaBoot
  } else if argv[0] == "clean" {
    command = LaputaClean
  }
  let command_name = command_text(command)

  if argv.len() < 2 {
    return Err(types.LaputaError.Usage(f"laputa ${command_name} requires a profile name\n\n${usage()}"))
  }

  let profile_name = argv[1]
  var jobs = 1
  var index = 2

  while index < argv.len() {
    let token = argv[index]

    if token == "--jobs" or token == "-j" {
      if command_name != "build" or index + 1 >= argv.len() {
        return Err(types.LaputaError.Usage(f"invalid ${token} for laputa ${command_name}"))
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

  match parsed.command {
    LaputaClean => {
      build.clean(fp"${root}/target/laputa/${value.name}")?
      print f"laputa clean ${value.name}: ok"
    }
    LaputaPlan => {
      let outputs = build.plan_profile(docker.build_config(root, value.name)?, value)?
      print f"laputa plan ${value.name} ${profile.digest(value)?} ${outputs.build_plan}"
    }
    LaputaTest => qemu.run_test(qemu.qemu_config(root)?, value, build.outputs(fp"${root}/target/laputa/${value.name}"))?
    LaputaBoot => qemu.boot(qemu.qemu_config(root)?, value, build.outputs(fp"${root}/target/laputa/${value.name}"))?
    LaputaBuild => {
      let _ = parsed.jobs
      build.unavailable("build")?
    }
  }
}
