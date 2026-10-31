#!/bin/xsh
error LoginShellError = Failed(message: Str)

proc main(...argv: List[Str]) [fs, process, env, error] {
  guard argv.len() == 2 and argv[0] == "-c" else {
    return Err(LoginShellError.Failed("xsh-login runs `-c SOURCE`; no interactive shell is installed"))
  }

  let scratch = fs.tempdir()?
  let source = fp"{scratch.host_path()?}/command.xsh"
  source.write(argv[1])?
  let status = process.run(process.command_argv(/bin/xsh, ["/bin/xsh", source.display()], fs.cwd()?, {}))?

  if ! status.ok {
    if status.exited() {
      exit status.exit_code()?
    }

    return Err(LoginShellError.Failed("the command was signaled"))
  }
}

main(@args)?
