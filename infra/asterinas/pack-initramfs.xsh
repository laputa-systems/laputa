##! Pack an initramfs root deterministically with direct tool invocations.
use hash

error InitramfsPackError = Failed

proc run_checked(executable: Str, argv: List[Str], cwd: Path, stdin = p"", stdout = p"") {
  let command = if stdin != "" and stdout != "" {
    process.command_argv(executable, argv, cwd, stdin:, stdout:)
  } else if stdin != "" {
    process.command_argv(executable, argv, cwd, stdin:)
  } else if stdout != "" {
    process.command_argv(executable, argv, cwd, stdout:)
  } else {
    process.command_argv(executable, argv, cwd)
  }
  let status = process.run(command)?
  return Err(InitramfsPackError.Failed(f"command failed: {argv.join(" ")}")) unless status.ok
}

proc docker_tool(docker_image: Str, tool: Str, args: List[Str], root: Path, stdin: Path, stdout: Path) {
  var argv = [
    "docker", "run", "--rm", "--interactive", "--pull", "never", "--platform", "linux/amd64", "--network", "none",
  ]

  if tool == "cpio" {
    argv += ["--mount", f"type=bind,src={root},dst=/rootfs,readonly", "--workdir", "/rootfs"]
  }

  argv += ["--entrypoint", f"/usr/bin/{tool}", docker_image, @args]
  run_checked("docker", argv, root, stdin:, stdout:)
}

proc main(root: Path, output: Path, docker_image: Str) [fs, process, error] {
  if ! root.exists() or ! root.is_dir() {
    return Err(InitramfsPackError.Failed(f"initramfs root is not a directory: {root}"))
  }

  let scratch = fs.tempdir()?
  let file_list = fp"{scratch.host_path()?}/files.list"
  let sorted_list = fp"{scratch.host_path()?}/files.sorted"
  let cpio_archive = fp"{scratch.host_path()?}/initramfs.cpio"
  let unpacked = fp"{scratch.host_path()?}/initramfs.unpacked.cpio"
  let listing = fp"{scratch.host_path()?}/initramfs.list"
  let output_tmp = fp"{output}.tmp"
  defer output_tmp.remove()

  run_checked(
    "/usr/bin/find",
    ["/usr/bin/find", ".", "-print0"],
    root,
    stdout: file_list,
  )
  run_checked(
    "/usr/bin/env",
    ["LC_ALL=C", "/usr/bin/sort", "-z"],
    root,
    stdin: file_list,
    stdout: sorted_list,
  )
  docker_tool(
    docker_image,
    "cpio",
    ["--null", "--create", "--format=newc", "--reproducible", "--owner=0:0"],
    root,
    sorted_list,
    cpio_archive,
  )
  docker_tool(docker_image, "gzip", ["-n", "-9", "-c"], root, cpio_archive, output_tmp)
  docker_tool(docker_image, "gzip", ["-t", "-"], root, output_tmp, p"")
  docker_tool(docker_image, "gzip", ["-d", "-c"], root, output_tmp, unpacked)
  docker_tool(docker_image, "cpio", ["--list", "--quiet"], root, unpacked, listing)

  let names = listing.read_lines()?
  if ! (names |> any . == "init" or . == "./init") {
    output_tmp.remove()
    return Err(InitramfsPackError.Failed("packed initramfs does not contain /init"))
  }

  output_tmp.rename(to: output, overwrite: true)
  print f"Initramfs SHA-256: {hash.sha256(output)?.hex()}"
}
