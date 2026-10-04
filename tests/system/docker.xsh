##! Behavior coverage for native Docker command construction.
use system.docker as docker
use system.profile as profile

pure fixture_config() -> docker.DockerConfig {
  {
    docker: p"docker",
    arch: "aarch64",
    platform: "linux/arm64",
    laputa_root: /work/laputa,
    seed: /work/laputa/.out/seed/aarch64,
    output_root: /work/laputa/target/laputa/qemu-dwl-foot,
    artifact_root: docker.artifact_store_root(/work/laputa, "aarch64"),
    image: "laputa-package-tools:aarch64-test",
    repo_url: "",
    owner: {uid: 1000, gid: 1000},
  }
}

test test_profile_plan_command_has_exact_direct_roots_and_kernel [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", p"profiles")?
  assert docker.docker_pm_plan_argv(value, "x86_64") == [
    "/bin/xsh",
    "/src/laputa/pm.xsh",
    "--",
    "repo",
    "plan",
    "--repo",
    "/src/laputa",
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
    "--target",
    "x86_64-linux-musl",
    "--output",
    "/output/build-plan.json",
  ]
  assert ! (docker.docker_pm_plan_argv(value, "x86_64") |> any "llvm-toolchain" in .)
}

test test_docker_rejects_a_runner_image_of_another_architecture [error] {
  docker.require_image_architecture("linux/arm64", "arm64")?
  docker.require_image_architecture("linux/amd64", "amd64")?

  for mismatch in [["linux/arm64", "amd64"], ["linux/amd64", "arm64"]] {
    match docker.require_image_architecture(mismatch[0], mismatch[1]) {
      Ok(_) => test.fail(f"{mismatch[1]} image accepted for {mismatch[0]}")?
      Err(_) => {}
    }
  }
}

test test_docker_places_optional_repository_configuration_before_image [error] {
  let argv = docker.docker_command_argv({...fixture_config(), repo_url: "https://packages.example.test"}, [])
  var image = 0

  while argv[image] != "laputa-package-tools:aarch64-test" {
    image += 1
  }

  assert argv[image - 2] == "--env"
  assert argv[image - 1] == "XSH_PM_REPO=https://packages.example.test"
  assert ! (argv |> any "XSH_PM_PUBLIC_REPO" in .)
}

test test_native_docker_command_mounts_only_declared_inputs [error] {
  let argv = docker.docker_command_argv(fixture_config(), ["/bin/xsh", "/src/laputa/pm.xsh", "--", "repo", "check"])
  assert argv[0] == "docker"
  assert "linux/arm64" in argv
  assert argv |> any "/src/laputa,readonly" in .
  assert ! (argv |> any "/src/packages" in .)
  assert "type=bind,src=/work/laputa/target/laputa/qemu-dwl-foot,dst=/output" in argv
  assert "type=bind,src=/work/laputa/.out/artifacts/aarch64,dst=/artifacts" in argv
  assert "type=bind,src=/work/laputa/.out/cache/linux-kbuild,dst=/var/cache/laputa/linux-kbuild" in argv
  assert ! (argv |> any "type=volume" in .)
  assert "XSH_MODULE_PATH=/src/laputa" in argv
  assert "XSH_PM_BOOTSTRAP_LLVM_ROOT=/usr/lib/llvm23" in argv
  assert ! (argv |> any "amd64" in .)
  assert ! (argv |> any "x86_64" in .)
}

test test_container_xsh_and_core_come_from_one_seed [error] {
  let argv = docker.docker_command_argv(fixture_config(), ["/bin/xsh", "--help"])
  for product in ["xsh", "xshi", "xsht"] {
    assert f"type=bind,src=/work/laputa/.out/seed/aarch64/{product},dst=/bin/{product},readonly" in argv
  }

  assert "type=bind,src=/work/laputa/.out/seed/aarch64/core,dst=/usr/lib/xsh/core,readonly" in argv
  assert ! (argv |> any "/work/xsh" in .)
}

test test_generation_projection_and_build_use_the_single_container_adapter [fs, error] {
  let value = profile.load_system_profile("qemu-dwl-foot", p"profiles")?
  assert docker.docker_generation_plan_argv(value) == [
    "/bin/xsh",
    "/src/laputa/system/container_build.xsh",
    "--",
    "plan",
    "qemu-dwl-foot",
    "1",
  ]
  assert docker.docker_profile_build_argv(value, 3) == [
    "/bin/xsh",
    "/src/laputa/system/container_build.xsh",
    "--",
    "build",
    "qemu-dwl-foot",
    "3",
  ]
}

test test_x86_64_docker_command_uses_the_amd64_platform_and_store [error] {
  let config = {
    ...fixture_config(),
    arch: "x86_64",
    platform: "linux/amd64",
    seed: /work/laputa/.out/seed/x86_64,
    artifact_root: docker.artifact_store_root(/work/laputa, "x86_64"),
  }
  let argv = docker.docker_command_argv(config, ["/bin/xsh", "--help"])
  assert "linux/amd64" in argv
  assert ! (argv |> any "arm64" in .)
  assert "type=bind,src=/work/laputa/.out/artifacts/x86_64,dst=/artifacts" in argv
  assert "type=bind,src=/work/laputa/.out/seed/x86_64/core,dst=/usr/lib/xsh/core,readonly" in argv
}
