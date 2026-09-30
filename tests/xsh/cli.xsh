##! Behavior coverage for the closed typed Laputa command parser.
use laputa.cli as laputa_cli

test test_laputa_cli_exports_the_closed_command_type [error] {
  let command: laputa_cli.LaputaCommand = laputa_cli.LaputaPlan
  laputa_cli.command_text(command) == "plan"
}

test test_laputa_cli_parses_only_typed_public_commands [error] {
  let planned = laputa_cli.parse(["plan", "qemu-dwl-foot"])?
  laputa_cli.command_text(planned.command) == "plan"
  planned.profile_name == "qemu-dwl-foot"

  let built = laputa_cli.parse(["build", "qemu-dwl-foot", "--jobs", "3"])?
  laputa_cli.command_text(built.command) == "build"
  built.jobs == 3

  for command in ["test", "boot"] {
    let ensured = laputa_cli.parse([command, "qemu-dwl-foot", "--jobs", "2"])?
    ensured.jobs == 2
  }

  for command in ["test", "boot", "clean"] {
    laputa_cli.command_text(laputa_cli.parse([command, "qemu-dwl-foot"])?.command) == command
  }
}

test test_laputa_cli_rejects_ambiguous_or_invalid_arguments [error] {
  for argv in [
    [
      "world-plan",
      "qemu-dwl-foot",
    ],
    [
      "plan",
    ],
    [
      "plan",
      "qemu-dwl-foot",
      "--jobs",
      "2",
    ],
    [
      "build",
      "qemu-dwl-foot",
      "--jobs",
      "0",
    ],
  ] {
    match laputa_cli.parse(argv) {
      Ok(_) => false
      Err(_) => {}
    }
  }
}

test test_laputa_test_and_boot_dispatch_through_the_current_build_path [fs, error] {
  let source = fs.read_text(p"laputa/cli.xsh")?
  """LaputaTest => {
      let outputs = build.build_profile""" in source
  """LaputaBoot => {
      let outputs = build.build_profile""" in source
  ! ("LaputaTest => qemu.run_test" in source)
  ! ("LaputaBoot => qemu.boot" in source)
}
