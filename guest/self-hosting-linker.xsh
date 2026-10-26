#!/bin/xsh --
error SelfHostingLinkerError = ExecutionFailed(message: Str, status: Status)

proc main(...linker_args: List[Str]) [process, env, error] -> Result[Unit, Error] {
  let command = process.command_argv(
    /usr/bin/clang,
    [
      "/usr/bin/clang",
      @linker_args,
      "-fuse-ld=/bin/mold",
      "-B/seed/rust/lib/rustlib/x86_64-unknown-linux-musl/lib/self-contained",
    ],
  )
  let status = process.run(command)?
  if ! status.exited() and ! status.signaled() {
    return Err(SelfHostingLinkerError.ExecutionFailed("Clang could not execute", status))
  }
  exit status.shell_code()?
}

main(@args)?
