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

proc main() [fs, process, env, time, net, error] {
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

  # A TCP echo over 127.0.0.1 exercises the guest network stack without host networking.
  let socket_abi = linux.net_constants()
  let server = linux.socket(socket_abi.AF_INET, socket_abi.SOCK_STREAM)?
  defer unix.close_fd(server)
  linux.bind(server, {family: "inet", address: "127.0.0.1", port: 0})?
  linux.listen(server, 1)?
  let local = linux.getsockname(server)?
  let client = linux.socket(socket_abi.AF_INET, socket_abi.SOCK_STREAM)?
  defer unix.close_fd(client)
  linux.connect(client, local)?
  let accepted = linux.accept(server)?
  defer unix.close_fd(accepted.fd)
  let request = bytes.from_text("laputa-loopback")
  require(
    unix.write_fd(client, request)? == request.len(),
    "loopback",
    "the XSH client could not write its TCP request",
  )?
  require(
    unix.poll_fd(accepted.fd, ["readable"], 1000)? == ["readable"],
    "loopback",
    "the XSH server did not become readable",
  )?
  let received = unix.read_fd(accepted.fd, 64)?
  require(received == request, "loopback", "the TCP request payload changed")?
  require(
    linux.sendto(accepted.fd, received)? == request.len(),
    "loopback",
    "the XSH server could not send its TCP response",
  )?
  let response = linux.recvfrom(client, 64)?
  require(response.data == request, "loopback", "the TCP response payload changed")?
  eprint --flush "LAPUTA_ASTERINAS_LOOPBACK_OK"

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
  var names = []
  for entry in fs.children(test_dir)? {
    names += [entry.name]
  }
  require("payload.txt" in names and "alias.txt" in names, "directory", "directory traversal missed an entry")?

  original.rename(to: renamed)?
  require(link.read_text()? == "second\n", "symlink", "a relative symlink did not resolve")?
  link.remove()?
  renamed.remove()?
  test_dir.remove()?

  let raw_tmp_dir = fp"/tmp/asterinas-raw-path-{process.current_pid()?}"
  raw_tmp_dir.mkdir()
  let raw_tmp_root = fs.open_root(raw_tmp_dir)?
  require(raw_tmp_dir.exists()?, "tmpfs-path", "new tmpfs directory is missing")?
  require(
    raw_tmp_root.children(p".")?.children.len() == 0,
    "tmpfs-path",
    "new tmpfs directory was not visible through rooted enumeration",
  )?
  let raw_name = b"raw\xfffile" as Path
  raw_tmp_root.write(raw_name, b"ok")
  require(raw_tmp_dir.exists()?, "tmpfs-path", "rooted create removed its parent path")?
  require(
    raw_tmp_root.children(p".")?.children == [raw_name],
    "tmpfs-path",
    "rooted directory enumeration lost the raw pathname bytes",
  )?
  let raw_tmp_entries = fs.children(raw_tmp_dir)?.collect()
  require(
    raw_tmp_entries.len() == 1
      and raw_tmp_entries[0].path.relative_to(raw_tmp_dir) == raw_name,
    "tmpfs-path",
    "pathname lookup did not find the rooted create through its parent path",
  )?
  raw_tmp_root.close()

  p"/var/lib/laputa/asterinas-ext2-write".write("Laputa XSH wrote to ext2\n")
  require(
    p"/var/lib/laputa/asterinas-ext2-write".read_text()? == "Laputa XSH wrote to ext2\n",
    "ext2",
    "the ext2 root did not preserve an XSH write",
  )?

  let test_selection_path = p"/usr/lib/asterinas/xsh-test.selection"

  if test_selection_path.exists()? {
    let source_root = p"/usr/lib/asterinas/xsh-source"
    # XSH's filesystem test checks the repository root marker and specification file.
    let git_marker = fp"{source_root}/.git"
    git_marker.mkdir(parents: true)
    let test_selection = test_selection_path.read_text()?.trim()
    eprint --flush f"LAPUTA_ASTERINAS_XSH_TEST_START {test_selection}"
    let test_run = cd (source_root) {
      if test_selection == "all" {
        run.capture --text HOME=/root XSH_MODULE_PATH="/usr/lib/xsh/core:/usr/lib/asterinas/xsh-source" /usr/bin/xsht test --jobs 1 --fail-fast --nocapture
      } else if "::" in test_selection {
        run.capture --text HOME=/root XSH_MODULE_PATH="/usr/lib/xsh/core:/usr/lib/asterinas/xsh-source" /usr/bin/xsht test --jobs 1 --fail-fast --nocapture --exact $test_selection
      } else {
        run.capture --text HOME=/root XSH_MODULE_PATH="/usr/lib/xsh/core:/usr/lib/asterinas/xsh-source" /usr/bin/xsht test --jobs 1 --fail-fast --nocapture $test_selection
      }
    }?
    eprint --flush $test_run.stdout
    eprint --flush $test_run.stderr
    require(
      test_run.status.exited_with(0)
        and "test result: ok." in test_run.stdout
        and ! ("test result: ok. 0 passed; 0 failed; 0 skipped" in test_run.stdout),
      "xsh-test",
      f"XSH test selection failed or discovered no tests: {test_selection}",
    )?
    eprint --flush "LAPUTA_ASTERINAS_XSH_TEST_OK"
  }

  eprint --flush "LAPUTA_ASTERINAS_XSH_OK"
  eprint --flush "LAPUTA_ASTERINAS_TEST_OK"
}

main()?
