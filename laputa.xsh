##! The explicit command entrypoint for Laputa's qemu-dwl-foot system profile.
#!/bin/xsh
use laputa.cli as laputa_cli

proc main(...argv: List[Str]) [fs, process, env, error] {
  laputa_cli.dispatch(argv)?
}

main(@args)?
