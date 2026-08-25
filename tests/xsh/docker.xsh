##! Behavior coverage for native arm64 Docker command construction.
use laputa.docker as docker

pure fixture_config() -> docker.DockerConfig {
  {
    docker: p"docker",
    packages_root: p"/work/packages",
    laputa_root: p"/work/laputa",
    xsh_root: p"/work/xsh",
    output_root: p"/work/laputa/target/laputa/qemu-dwl-foot",
    artifact_volume: "laputa-artifacts-aarch64-v1",
    source_volume: "laputa-sources-aarch64-v1",
    image: "laputa-package-tools",
  }
}

proc test_native_arm64_docker_command_mounts_only_declared_inputs() [error] {
  let argv = docker.command_argv(fixture_config(), ["/bin/xsh", "/src/packages/pm.xsh", "--", "repo", "check"])
  test.eq(argv[0], "docker")?
  test.ok("linux/arm64" in argv)?
  test.ok(argv |> any .contains("/src/packages,readonly"))?
  test.ok(argv |> any .contains("/src/laputa,readonly"))?
  test.ok(argv |> any .contains("/usr/lib/xsh/core,readonly"))?
  test.ok(argv |> any .contains("dst=/output"))?
  test.ok(argv |> any .contains("laputa-artifacts-aarch64-v1"))?
  test.ok(argv |> any .contains("laputa-sources-aarch64-v1"))?
  test.ok(! (argv |> any .contains("amd64")))?
  test.ok(! (argv |> any .contains("x86_64")))?
}
