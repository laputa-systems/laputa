##! Explicit command parsing for the single qemu-dwl-foot Laputa profile.
use system.build
use system.docker
use system.profile
use system.qemu
use system.types

## The closed public Laputa command surface; all execution choices are explicit command data.
export enum LaputaCommand {
    LaputaPlan,
    LaputaBuild,
    LaputaTest,
    LaputaBoot,
    LaputaClean,
}

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

Build and test the one supported reference system natively for this host:
aarch64 under HVF on macOS, aarch64 or x86_64 under KVM on Linux.
"""
}

## Decode command arguments without filesystem-dependent interpretation.
export proc parse(argv: List[Str]) [error] -> Result[CliArgs, Error] {
  if argv.is_empty() or argv[0] == "--help" or argv[0] == "-h" {
    return Err(types.LaputaError.Usage(usage()))
  }

  if argv[0] != "plan" and argv[0] != "build" and argv[0] != "test" and argv[0] != "boot" and argv[0] != "clean" {
    return Err(
      types.LaputaError.Usage(f"""unknown laputa command {argv[0]}

{usage()}"""),
    )
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
    return Err(
      types.LaputaError.Usage(f"""laputa {command_name} requires a profile name

{usage()}"""),
    )
  }

  let profile_name = argv[1]
  var jobs = 1
  var index = 2

  while index < argv.len() {
    let token = argv[index]

    if token == "--jobs" or token == "-j" {
      if (command_name != "build" and command_name != "test" and command_name != "boot") or index + 1 >= argv.len() {
        return Err(types.LaputaError.Usage(f"invalid {token} for laputa {command_name}"))
      }

      jobs = argv[index + 1].parse_int()?
      return Err(types.LaputaError.Usage("--jobs must be positive")) when jobs <= 0

      index += 2
      continue
    }

    return Err(
      types.LaputaError.Usage(f"""unexpected argument {token}

{usage()}"""),
    )
  }

  {command, profile_name, jobs}
}

## Run the profile command through typed profile validation and Docker configuration.
export proc dispatch(argv: List[Str]) [fs, process, env, time, error] {
  let parsed = parse(argv)?
  let root = fs.cwd()?
  let value = profile.load_system_profile(parsed.profile_name, fp"{root}/profiles")?
  # The image is built in native Docker and booted with hardware acceleration,
  # so its architecture is always the host's.
  let target = qemu.host_qemu_target()?

  match parsed.command {
    LaputaClean => {
      build.clean(fp"{root}/target/laputa/{value.name}")
      print f"laputa clean {value.name}: ok"
    }
    LaputaPlan => {
      let outputs = build.plan_system_profile(docker.build_config(root, value.name, target.arch)?, value)?
      print f"laputa plan {value.name} {profile.digest(value)?} {outputs.build_plan}"
    }
    LaputaTest => {
      let outputs = build.build_profile(docker.build_config(root, value.name, target.arch)?, value, parsed.jobs)?
      qemu.run_test(qemu.qemu_config(root, target)?, value, outputs)
    }
    LaputaBoot => {
      let outputs = build.build_profile(docker.build_config(root, value.name, target.arch)?, value, parsed.jobs)?
      qemu.boot(qemu.qemu_config(root, target)?, value, outputs)
    }
    LaputaBuild => {
      let _ = build.build_profile(docker.build_config(root, value.name, target.arch)?, value, parsed.jobs)?
      print f"laputa build {value.name}: ok"
    }
  }
}
