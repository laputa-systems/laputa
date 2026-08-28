##! Behavior coverage for native arm64 Docker command construction.
use laputa.docker as docker
use laputa.profile as profile

pure fixture_config() -> docker.DockerConfig {
  {
    docker: p"docker",
    packages_root: p"/work/packages",
    laputa_root: p"/work/laputa",
    xsh_root: p"/work/xsh",
    output_root: p"/work/laputa/target/laputa/qemu-dwl-foot",
    artifact_volume: "laputa-artifacts-aarch64-v2",
    source_volume: "laputa-sources-aarch64-v2",
    image: "laputa-package-tools",
    repo_url: "",
  }
}

proc test_profile_plan_command_has_exact_direct_roots_and_kernel() [fs, error] {
  let value = profile.load("qemu-dwl-foot", p"profiles")?
  test.eq(
    docker.docker_pm_plan_argv(value),
    [
      "/bin/xsh", "/src/packages/pm.xsh", "--", "repo", "plan", "--repo", "/src/packages",
      "--root", "baselayout",
      "--root", "xsh",
      "--root", "laputa-pm",
      "--root", "xinit",
      "--root", "mdevd",
      "--root", "seatd",
      "--root", "dwl-minimal",
      "--root", "foot-minimal",
      "--root", "linux",
      "--output", "/output/build-plan.json",
    ],
  )?
  test.ok(! (docker.docker_pm_plan_argv(value) |> any .contains("llvm-toolchain")))?
}

proc test_docker_rejects_non_arm64_runner_architecture() [error] {
  docker.require_arm64_image_architecture("arm64")?
  match docker.require_arm64_image_architecture("amd64") {
    Ok(_) => test.ok(false)?
    Err(_) => {}
  }
}

proc test_docker_places_optional_repository_configuration_before_image() [error] {
  let argv = docker.docker_command_argv({...fixture_config(), repo_url: "https://packages.example.test"}, [])
  test.eq(argv[23], "--env")?
  test.eq(argv[24], "XSH_PM_REPO=https://packages.example.test")?
  test.eq(argv[25], "--env")?
  test.eq(argv[26], "XSH_PM_PUBLIC_REPO=https://packages.example.test")?
  test.eq(argv[27], "laputa-package-tools")?
}

proc test_native_arm64_docker_command_mounts_only_declared_inputs() [error] {
  let argv = docker.docker_command_argv(fixture_config(), ["/bin/xsh", "/src/packages/pm.xsh", "--", "repo", "check"])
  test.eq(argv[0], "docker")?
  test.ok("linux/arm64" in argv)?
  test.ok(argv |> any .contains("/src/packages,readonly"))?
  test.ok(argv |> any .contains("/src/laputa,readonly"))?
  test.ok(argv |> any .contains("/usr/lib/xsh/core,readonly"))?
  test.ok(argv |> any .contains("dst=/output"))?
  test.ok(argv |> any .contains("laputa-artifacts-aarch64-v2"))?
  test.ok(argv |> any .contains("laputa-sources-aarch64-v2"))?
  test.ok("XSH_MODULE_PATH=/src/packages:/src/laputa" in argv)?
  test.ok(! (argv |> any .contains("XSH_MODULE_PATH=/src/laputa:/src/packages")))?
  test.ok(! (argv |> any .contains("amd64")))?
  test.ok(! (argv |> any .contains("x86_64")))?
}

proc test_generation_projection_and_build_use_the_single_container_adapter() [fs, error] {
  let value = profile.load("qemu-dwl-foot", p"profiles")?
  test.eq(
    docker.docker_generation_plan_argv(value),
    ["/bin/xsh", "/src/laputa/laputa/container_build.xsh", "--", "plan", "qemu-dwl-foot", "1"],
  )?
  test.eq(
    docker.docker_profile_build_argv(value, 3),
    ["/bin/xsh", "/src/laputa/laputa/container_build.xsh", "--", "build", "qemu-dwl-foot", "3"],
  )?
}

proc package_tools_fixture(ctx: TestContext) [fs, error] -> Result[docker.DockerConfig] {
  let root = test.temp_dir(ctx, name: "package-tools")?
  fs.write(fp"${root}/Dockerfile.package-tools", "FROM scratch\n")?
  fs.write(fp"${root}/bootstrap-llvm-seed.xsh", "seed\n")?
  fs.mkdir(fp"${root}/packages/pm")?
  fs.mkdir(fp"${root}/packages/repo/llvm-toolchain")?
  fs.write(fp"${root}/packages/pm.xsh", "pm entrypoint\n")?
  fs.write(fp"${root}/packages/pm/cli.xsh", "pm module\n")?
  fs.write(fp"${root}/packages/repo/llvm-toolchain/PKGBUILD.xsh", "llvm seed\n")?
  {
    docker: p"docker",
    packages_root: fp"${root}/packages",
    laputa_root: root,
    xsh_root: fp"${root}/xsh",
    output_root: fp"${root}/output",
    artifact_volume: "artifacts",
    source_volume: "sources",
    image: "laputa-package-tools",
    repo_url: "",
  }
}

proc test_package_tools_input_key_and_tag_are_deterministic(ctx: TestContext) [fs, env, error] {
  let value = package_tools_fixture(ctx)?
  let first = docker.package_tools_image_tag(value)?
  let second = docker.package_tools_image_tag(value)?
  test.eq(first, second)?
  test.ok(first.starts_with("laputa-package-tools:arm64-"))?
  fs.write(fp"${value.packages_root}/pm/cli.xsh", "changed pm module\n")?
  test.eq(docker.package_tools_image_tag(value)? == first, false)?
}

proc test_package_tools_requires_the_focused_bootstrap_contract(ctx: TestContext) [fs, process, env, error] {
  let root = test.temp_dir(ctx, name: "package-tools-missing")?
  let value: docker.DockerConfig = {
    docker: p"docker",
    packages_root: fp"${root}/packages",
    laputa_root: root,
    xsh_root: fp"${root}/xsh",
    output_root: fp"${root}/output",
    artifact_volume: "artifacts",
    source_volume: "sources",
    image: "laputa-package-tools",
    repo_url: "",
  }

  match docker.ensure_package_tools(value) {
    Ok(_) => test.fail("missing Dockerfile.package-tools unexpectedly succeeded")?
    Err(problem) => test.contains(problem.message, "Dockerfile.package-tools")?,
  }
}

proc test_package_tools_build_is_native_arm64_and_tagged(ctx: TestContext) [fs, error] {
  let value = package_tools_fixture(ctx)?
  let argv = docker.package_tools_build_argv(value, "laputa-package-tools:arm64-test")
  test.ok("linux/arm64" in argv)?
  test.ok("laputa-package-tools:arm64-test" in argv)?
  test.ok(! (argv |> any .contains("amd64")))?
  test.ok(! (argv |> any .contains("x86_64")))?
}

proc test_package_tools_dockerfile_has_the_native_runtime_contract() [fs, error] {
  let source = fs.read_text(p"Dockerfile.package-tools")?
  test.ok("FROM alpine:3.21@sha256:" in source)?
  test.ok("linux/arm64" in source)?
  test.ok("/bin/xsh" in source)?
  test.ok("bootstrap-llvm-seed.xsh" in source)?
  test.ok("mkfs.ext4.xsh" in source)?
  test.ok("e2fsprogs" in source)?
  test.ok("util-linux" in source)?
  test.ok("/src/packages" in source)?
  test.ok("/src/laputa" in source)?
  test.ok(! ("amd64" in source))?
  test.ok(! ("x86_64" in source))?
}
