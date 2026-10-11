#!/bin/xsh --
error AsterinasProofError = Failed(phase: Str, message: Str)

proc require(condition: Bool, phase: Str, message: Str) {
  if ! condition {
    print f"LAPUTA_ASTERINAS_TEST_FAILED {phase}: {message}"
    return Err(AsterinasProofError.Failed(phase:, message:))
  }
}

pure doubled(value: Int) -> Int {
  value * 2
}

proc main() [fs, process, env, time, error] {
  eprint --flush "LAPUTA_ASTERINAS_XINIT_PID1_START"
  # xinit reaches this sysinit only after its production PID 1 guard succeeds.
  eprint --flush "LAPUTA_ASTERINAS_XINIT_PID1_OK"

  require(linux.is_mountpoint(/proc)?, "proc", "/proc is not mounted")?
  require(linux.is_mountpoint(/sys)?, "sysfs", "/sys is not mounted")?
  require(linux.is_mountpoint(/dev)?, "dev", "/dev is not mounted")?

  let os_release = p"/etc/os-release".read_text()?
  require("NAME=\"Laputa Linux\"" in os_release, "rootfs", "Laputa os-release is missing")?
  eprint --flush "LAPUTA_ASTERINAS_ROOTFS_OK"

  require(doubled(21) == 42, "evaluation", "typed XSH evaluation returned the wrong result")?

  let xsh_help = run.text /usr/bin/xsh --help
  require("xsh SCRIPT" in xsh_help, "xsh", "the packaged XSH interpreter did not print its usage")?

  let pm_help = run.text /usr/bin/pm --help
  require("usage: pm" in pm_help, "pm", "the packaged PM wrapper did not print its usage")?

  let module_path = run.text /usr/bin/printenv XSH_MODULE_PATH
  require(
    module_path.trim() == "/usr/lib/xsh/core",
    "module-path",
    "the packaged core module directory is missing from the process environment",
  )?

  let core_report = run.text /usr/bin/system-report --version
  require("system-report schema v1" in core_report, "core-module", "the installed core command did not load its library")?

  let stdout_stderr = run.capture --text /usr/bin/xsh /usr/lib/asterinas/stdio-child.xsh
  require(stdout_stderr.status.exited_with(0), "stdio", "the XSH child did not exit successfully")?
  require(stdout_stderr.stdout.trim() == "LAPUTA_CHILD_STDOUT", "stdout", "child stdout was not captured")?
  require(stdout_stderr.stderr.trim() == "LAPUTA_CHILD_STDERR", "stderr", "child stderr was not captured")?

  let environment = run.text LAPUTA_GUEST_ENV=visible /usr/bin/printenv LAPUTA_GUEST_ENV
  require(environment.trim() == "visible", "environment", "the child did not inherit its scoped environment")?

  let pipeline = run.text /usr/bin/printf "laputa\n" | run /usr/bin/tr a-z A-Z
  require(pipeline.trim() == "LAPUTA", "pipeline", "the XSH pipeline produced the wrong output")?

  let failed_child = run.status /usr/bin/false
  require(failed_child.exited_with(1), "process-status", "the child exit status was not preserved")?

  let worker = spawn run /usr/bin/sleep 30 ?
  worker.cancel(signal: "TERM", kill_after: 2s)

  let generation = p"/var/lib/laputa/generation.json".read_text()?

  for package in ["baselayout", "xsh", "laputa-pm", "xinit"] {
    require(package in generation, "generation", f"runtime generation is missing {package}")?
  }

  let test_dir = fp"/var/lib/laputa/asterinas-test-{process.current_pid()?}"
  test_dir.mkdir()
  let original = fp"{test_dir}/payload.txt"
  original.write("first\n")
  require(original.read_text()? == "first\n", "filesystem", "created file content could not be read")?
  original.write("second\n")
  require(original.read_text()? == "second\n", "filesystem", "modified file content was not visible")?
  original.chmod(0o600)?
  require(original.metadata()?.mode % 4096 == 0o600, "permissions", "file mode did not persist")?

  let renamed = fp"{test_dir}/renamed.txt"
  let link = fp"{test_dir}/alias.txt"
  link.symlink(to: p"renamed.txt")?
  var names: List[Str] = []
  for entry in fs.children(test_dir)? {
    names += [entry.name]
  }
  require("payload.txt" in names and "alias.txt" in names, "directory", "directory traversal missed an entry")?

  original.rename(to: renamed)?
  require(link.read_text()? == "second\n", "symlink", "a relative symlink did not resolve")?
  link.remove()?
  renamed.remove()?
  test_dir.remove()?

  p"/var/lib/laputa/asterinas-ext2-write".write("Laputa XSH wrote to ext2\n")
  require(
    p"/var/lib/laputa/asterinas-ext2-write".read_text()? == "Laputa XSH wrote to ext2\n",
    "ext2",
    "the ext2 root did not preserve an XSH write",
  )?
  eprint --flush "LAPUTA_ASTERINAS_XSH_OK"
  eprint --flush "LAPUTA_ASTERINAS_TEST_OK"
}

main()?
