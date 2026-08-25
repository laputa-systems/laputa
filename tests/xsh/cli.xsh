##! Behavior coverage for the closed typed Laputa command parser.
use laputa.cli as laputa_cli

proc test_laputa_cli_parses_only_typed_public_commands() [error] {
  let planned = laputa_cli.parse(["plan", "qemu-dwl-foot"])?
  test.eq(laputa_cli.command_text(planned.command), "plan")?
  test.eq(planned.profile_name, "qemu-dwl-foot")?

  let built = laputa_cli.parse(["build", "qemu-dwl-foot", "--jobs", "3"])?
  test.eq(laputa_cli.command_text(built.command), "build")?
  test.eq(built.jobs, 3)?

  for command in ["test", "boot", "clean"] {
    test.eq(laputa_cli.command_text(laputa_cli.parse([command, "qemu-dwl-foot"])?.command), command)?
  }
}

proc test_laputa_cli_rejects_ambiguous_or_invalid_arguments() [error] {
  for argv in [
    ["world-plan", "qemu-dwl-foot"],
    ["plan"],
    ["test", "qemu-dwl-foot", "--jobs", "2"],
    ["build", "qemu-dwl-foot", "--jobs", "0"],
  ] {
    match laputa_cli.parse(argv) {
      Ok(_) => test.ok(false)?
      Err(_) => {}
    }
  }
}
