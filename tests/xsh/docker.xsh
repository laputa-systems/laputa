##! Behavior coverage for native arm64 Docker command construction.
use laputa.docker as docker
use laputa.profile as profile

pure fixture_config() -> docker.DockerConfig {
  {
    docker: p"docker",
    packages_root: /work/packages,
    laputa_root: /work/laputa,
    xsh_root: /work/xsh,
    output_root: /work/laputa/target/laputa/qemu-dwl-foot,
    artifact_volume: "laputa-artifacts-aarch64-v2",
    source_volume: "laputa-sources-aarch64-v2",
    image: "laputa-package-tools",
    repo_url: "",
    container_xsh: docker.PinnedXsh,
  }
}

test test_profile_plan_command_has_exact_direct_roots_and_kernel [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", p"profiles")?
  docker.docker_pm_plan_argv(value) == [
    "/bin/xsh",
    "/src/packages/pm.xsh",
    "--",
    "repo",
    "plan",
    "--repo",
    "/src/packages",
    "--root",
    "baselayout",
    "--root",
    "xsh",
    "--root",
    "laputa-pm",
    "--root",
    "xinit",
    "--root",
    "mdevd",
    "--root",
    "seatd",
    "--root",
    "dwl-minimal",
    "--root",
    "foot-minimal",
    "--root",
    "linux",
    "--output",
    "/output/build-plan.json",
  ]
  ! (docker.docker_pm_plan_argv(value) |> any "llvm-toolchain" in .)
}

test test_docker_rejects_non_arm64_runner_architecture [error] {
  docker.require_arm64_image_architecture("arm64")?
  match docker.require_arm64_image_architecture("amd64") {
    Ok(_) => false
    Err(_) => {}
  }
}

test test_docker_places_optional_repository_configuration_before_image [error] {
  let argv = docker.docker_command_argv({...fixture_config(), repo_url: "https://packages.example.test"}, [])
  argv[25] == "--env"
  argv[26] == "XSH_PM_REPO=https://packages.example.test"
  argv[27] == "--env"
  argv[28] == "XSH_PM_PUBLIC_REPO=https://packages.example.test"
  argv[29] == "laputa-package-tools"
}

test test_native_arm64_docker_command_mounts_only_declared_inputs [error] {
  let argv = docker.docker_command_argv(fixture_config(), ["/bin/xsh", "/src/packages/pm.xsh", "--", "repo", "check"])
  argv[0] == "docker"
  "linux/arm64" in argv
  argv |> any "/src/packages,readonly" in .
  argv |> any "/src/laputa,readonly" in .
  argv |> any "/usr/lib/xsh/core,readonly" in .
  argv |> any "dst=/output" in .
  argv |> any "laputa-artifacts-aarch64-v2" in .
  argv |> any "laputa-sources-aarch64-v2" in .
  "XSH_MODULE_PATH=/src/packages:/src/laputa" in argv
  "XSH_PM_BOOTSTRAP_LLVM_ROOT=/usr/lib/llvm23" in argv
  ! (argv |> any "XSH_MODULE_PATH=/src/laputa:/src/packages" in .)
  ! (argv |> any "amd64" in .)
  ! (argv |> any "x86_64" in .)
}

test test_local_xsh_binary_mount_is_explicit_and_read_only [error] {
  let value = {
    ...fixture_config(),
    container_xsh: docker.CheckedOutXsh(/work/xsh/target/aarch64-unknown-linux-musl/debug/xsh),
  }
  let argv = docker.docker_command_argv(value, ["/bin/xsh", "--help"])
  argv |> any "src=/work/xsh/target/aarch64-unknown-linux-musl/debug/xsh,dst=/bin/xsh,readonly" in .
}

test test_generation_projection_and_build_use_the_single_container_adapter [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", p"profiles")?
  docker.docker_generation_plan_argv(value) == [
    "/bin/xsh",
    "/src/laputa/laputa/container_build.xsh",
    "--",
    "plan",
    "qemu-dwl-foot",
    "1",
  ]
  docker.docker_profile_build_argv(value, 3) == [
    "/bin/xsh",
    "/src/laputa/laputa/container_build.xsh",
    "--",
    "build",
    "qemu-dwl-foot",
    "3",
  ]
}

proc package_tools_fixture(ctx: TestContext) [fs, error] -> Result[docker.DockerConfig] {
  let root = test.temp_dir(ctx, name: "package-tools")?
  fs.write(
    fp"${root}/Dockerfile.package-tools",
    """FROM scratch
""",
  )?
  fs.write(
    fp"${root}/bootstrap-llvm-seed.xsh",
    """seed
""",
  )?
  fs.mkdir(fp"${root}/packages/pm")?
  fs.mkdir(fp"${root}/packages/repo/llvm-toolchain")?
  fs.write(
    fp"${root}/packages/pm.xsh",
    """pm entrypoint
""",
  )?
  fs.write(
    fp"${root}/packages/pm/cli.xsh",
    """pm module
""",
  )?
  fs.write(
    fp"${root}/packages/repo/llvm-toolchain/PKGBUILD.xsh",
    """llvm seed
""",
  )?
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
    container_xsh: docker.PinnedXsh,
  }
}

test test_package_tools_input_key_and_tag_are_deterministic [fs, env, error] { |ctx|
  let value = package_tools_fixture(ctx)?
  let first = docker.package_tools_image_tag(value)?
  let second = docker.package_tools_image_tag(value)?
  first == second
  first.starts_with("laputa-package-tools:arm64-")
  fs.write(
    fp"${value.packages_root}/pm/cli.xsh",
    """changed pm module
""",
  )?
  (docker.package_tools_image_tag(value)? == first) == false
}

test test_package_tools_requires_the_focused_bootstrap_contract [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "package-tools-missing")?
  let value: docker.DockerConfig = docker.DockerConfig(
    docker: p"docker",
    packages_root: fp"${root}/packages",
    laputa_root: root,
    xsh_root: fp"${root}/xsh",
    output_root: fp"${root}/output",
    artifact_volume: "artifacts",
    source_volume: "sources",
    image: "laputa-package-tools",
    repo_url: "",
    container_xsh: docker.PinnedXsh,
  )

  match docker.ensure_package_tools(value) {
    Ok(_) => test.fail("missing Dockerfile.package-tools unexpectedly succeeded")?
    Err(problem) => "Dockerfile.package-tools" in problem.message
  }
}

test test_package_tools_build_is_native_arm64_and_tagged [fs, error] { |ctx|
  let value = package_tools_fixture(ctx)?
  let argv = docker.package_tools_build_argv(value, "laputa-package-tools:arm64-test")
  "linux/arm64" in argv
  "laputa-package-tools:arm64-test" in argv
  ! (argv |> any "amd64" in .)
  ! (argv |> any "x86_64" in .)
}

test test_package_tools_dockerfile_has_the_native_runtime_contract [fs, error] {
  let source = fs.read_text(p"Dockerfile.package-tools")?
  "FROM alpine:3.21@sha256:" in source
  "linux/arm64" in source
  "/bin/xsh" in source
  "bootstrap-llvm-seed.xsh" in source
  "mkfs.ext4.xsh" in source
  "e2fsprogs" in source
  "util-linux" in source
  "/src/packages" in source
  "/src/laputa" in source
  ! ("amd64" in source)
  ! ("x86_64" in source)
}
