##! The explicit command entrypoint for Laputa's QEMU system profiles.
#!/bin/xsh
use system.cli as laputa_cli

proc main(...argv: List[Str]) [fs, process, env, time, error] {
  laputa_cli.dispatch(argv)
}
