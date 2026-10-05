##! Behavior coverage for the local XSH seed and the content-keyed Laputa images.
use pm.fingerprint as pm_fingerprint
use pm.recipe as pm_recipe
use pm.types as pm_types
use seed.images
use seed.world
use seed.xsh_seed

test test_seed_arch_names_each_tool_target [error] {
  let arm = xsh_seed.xsh_seed_arch("aarch64")?
  assert arm.triple == "aarch64-unknown-linux-musl"
  assert arm.docker_platform == "linux/arm64"
  let amd = xsh_seed.xsh_seed_arch("x86_64")?
  assert amd.triple == "x86_64-unknown-linux-musl"
  assert amd.docker_platform == "linux/amd64"

  match xsh_seed.xsh_seed_arch("riscv64") {
    Ok(_) => assert false
    Err(_) => {}
  }
}

test test_seed_build_is_an_offline_static_release_build_in_xsh_test [error] {
  let value = xsh_seed.xsh_seed_arch("aarch64")?
  let argv = xsh_seed.xsh_seed_cargo_build_argv(p"docker", /work/laputa, /work/xsh, value, 4)?
  assert xsh_seed.xsh_seed_build_image in argv
  assert "--network" in argv and "none" in argv
  assert "--locked" in argv and "--offline" in argv and "--release" in argv
  assert ! ("--profile" in argv)
  assert ! (argv |> any "dist" in .)
  assert "CARGO_PROFILE_RELEASE_INCREMENTAL=true" in argv
  assert "aarch64-unknown-linux-musl" in argv
  assert "type=bind,src=/work/xsh,dst=/work,readonly" in argv
  assert "type=bind,src=/work/laputa/.out/xsh-target,dst=/target" in argv
  assert "type=bind,src=/work/laputa/.cache/cargo/registry,dst=/root/.cargo/registry" in argv
  let rustflags = argv |> where .starts_with("CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS=")
  assert rustflags.len() == 1
  assert "+crt-static" in rustflags[0]
  assert "__isoc23_sscanf=sscanf" in rustflags[0]
}

test test_seed_core_layout_matches_xsh_release_packaging [error] {
  assert xsh_seed.xsh_seed_core_install_path(p"ls.xsh") == p"core/ls"
  assert xsh_seed.xsh_seed_core_install_path(p"system-report.xsh") == p"core/system-report"
  assert xsh_seed.xsh_seed_core_install_path(p"lib/auth.xsh") == p"core/lib/auth.xsh"
}

proc write_seed(ctx: TestContext) -> Result[Path] {
  let root = test.temp_dir(ctx, name: "seed-root")?
  let seed = xsh_seed.xsh_seed_dir(root, "aarch64")
  fs.mkdir(fp"{seed}/core")
  var files: Map[Str] = {}

  for name in ["xsh", "xshi", "xsht", "core.tar.xz"] {
    fs.write(fp"{seed}/{name}", f"{name} bytes\n")
    files[name] = hash.sha256(fp"{seed}/{name}")?.hex()
  }

  json.write(xsh_seed.xsh_seed_manifest_path(root, "aarch64"), {format: "laputa-xsh-seed-1", files})
  root
}

test test_seed_require_accepts_a_seed_matching_its_manifest [fs, error] { |ctx|
  let root = write_seed(ctx)?
  assert xsh_seed.xsh_seed_require(root, "aarch64")? == xsh_seed.xsh_seed_dir(root, "aarch64")
}

test test_seed_require_rejects_a_missing_seed [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "no-seed")?

  match xsh_seed.xsh_seed_require(root, "aarch64") {
    Ok(_) => test.fail("a missing seed was accepted")
    Err(problem) => assert "make seed" in problem.message
  }
}

test test_seed_require_rejects_a_product_that_differs_from_its_manifest [fs, error] { |ctx|
  let root = write_seed(ctx)?
  fs.write(fp"{xsh_seed.xsh_seed_dir(root, "aarch64")}/xshi", "a different build\n")

  match xsh_seed.xsh_seed_require(root, "aarch64") {
    Ok(_) => test.fail("a mismatched seed product was accepted")
    Err(problem) => assert "xshi" in problem.message
  }
}

test test_seed_mounts_binaries_and_core_from_one_directory [error] {
  let argv = xsh_seed.xsh_seed_mount_argv(/s)
  assert argv == [
    "--mount",
    "type=bind,src=/s/xsh,dst=/bin/xsh,readonly",
    "--mount",
    "type=bind,src=/s/xshi,dst=/bin/xshi,readonly",
    "--mount",
    "type=bind,src=/s/xsht,dst=/bin/xsht,readonly",
    "--mount",
    "type=bind,src=/s/core,dst=/usr/lib/xsh/core,readonly",
  ]
}

proc image_fixture(ctx: TestContext) -> Result[Path] {
  let root = test.temp_dir(ctx, name: "images")?
  fs.mkdir(fp"{root}/seed")
  fs.mkdir(fp"{root}/pm")
  fs.mkdir(fp"{root}/packages/llvm-toolchain")
  fs.write(fp"{root}/seed/Dockerfile.host-tools", "FROM alpine\n")
  fs.write(fp"{root}/Dockerfile.package-tools", "FROM base\n")
  fs.write(fp"{root}/bootstrap-llvm-seed.xsh", "seed helper\n")
  fs.write(fp"{root}/packages/llvm-toolchain/PKGBUILD.xsh", "llvm recipe\n")
  fs.write(fp"{root}/pm/cli.xsh", "pm module\n")
  root
}

test test_image_tags_are_content_keys_over_their_own_inputs [fs, error] { |ctx|
  let root = image_fixture(ctx)?
  let value = xsh_seed.xsh_seed_arch("aarch64")?
  let host = images.host_tools_tag(root, value)?
  let tools = images.package_tools_tag(root, value)?
  assert host.starts_with("laputa-host-tools:aarch64-")
  assert tools.starts_with("laputa-package-tools:aarch64-")
  assert images.package_tools_tag(root, value)? == tools

  # XSH and PM run in containers from mounts; editing them rebuilds no image.
  fs.write(fp"{root}/pm/cli.xsh", "changed pm module\n")
  assert images.package_tools_tag(root, value)? == tools
  assert images.host_tools_tag(root, value)? == host

  fs.write(fp"{root}/packages/llvm-toolchain/PKGBUILD.xsh", "changed llvm recipe\n")
  assert images.package_tools_tag(root, value)? != tools
  assert images.host_tools_tag(root, value)? == host

  fs.write(fp"{root}/seed/Dockerfile.host-tools", "FROM alpine\nRUN true\n")
  assert images.host_tools_tag(root, value)? != host
}

test test_package_tools_requires_its_dockerfile [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "images-missing")?
  fs.mkdir(fp"{root}/seed")
  fs.write(fp"{root}/seed/Dockerfile.host-tools", "FROM alpine\n")

  match images.package_tools_tag(root, xsh_seed.xsh_seed_arch("aarch64")?) {
    Ok(_) => test.fail("a missing Dockerfile.package-tools was accepted")
    Err(problem) => assert "Dockerfile.package-tools" in problem.message
  }
}

test test_package_tools_build_is_offline_and_native [error] {
  let value = xsh_seed.xsh_seed_arch("aarch64")?
  let argv = images.package_tools_build_argv(
    p"docker",
    /work/laputa,
    value,
    "laputa-host-tools:aarch64-a",
    "laputa-package-tools:aarch64-b",
    /work/laputa/.out/package-tools/aarch64/sources,
  )
  assert "--network" in argv and "none" in argv
  assert "linux/arm64" in argv
  assert "HOST_TOOLS_IMAGE=laputa-host-tools:aarch64-a" in argv
  assert "seed=/work/laputa/.out/seed/aarch64" in argv
  assert "sources=/work/laputa/.out/package-tools/aarch64/sources" in argv
  assert ! (argv |> any "amd64" in .)
}

test test_image_dockerfiles_take_only_local_inputs [fs, error] {
  let host = fs.read_text(p"seed/Dockerfile.host-tools")?
  assert "FROM alpine:3.21@sha256:" in host
  assert "e2fsprogs" in host
  assert "util-linux" in host

  let tools = fs.read_text(p"Dockerfile.package-tools")?
  assert r"FROM ${HOST_TOOLS_IMAGE}" in tools
  assert "bootstrap-llvm-seed.xsh" in tools
  assert "/src/laputa" in tools
  assert ! ("ADD " in tools)
  assert ! ("http" in tools)
  assert ! ("COPY --from=seed" in tools)
  assert ! ("/src/packages" in tools)
}

# The `xsh` package is the seed: a rebuilt seed must change its build key even
# though `.out/` is gitignored and the repository source uses `SKIP`.
test test_xsh_package_key_follows_the_seed_bytes [fs, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "xsh-package-key")?
  fs.symlink(fp"{fs.cwd()?}/packages", fp"{root}/packages")
  let seed = xsh_seed.xsh_seed_dir(root, "aarch64")
  fs.mkdir(fp"{seed}/core")

  for name in ["xsh", "xshi", "xsht", "core.tar.xz", "manifest.json", "core/ls"] {
    fs.write(fp"{seed}/{name}", f"first {name}\n")
  }

  let target = pm_types.parse_target("aarch64")?
  let pkg = pm_recipe.load_package_for_target(fp"{root}/packages/xsh", target)?
  let first = pm_fingerprint.package_build_input(root, pkg, target)?
  assert pm_fingerprint.package_build_input(root, pkg, target)? == first

  fs.write(fp"{seed}/xshi", "rebuilt xshi\n")
  assert pm_fingerprint.package_build_input(root, pkg, target)? != first
}

test test_world_selection_maps_packages_stop_lines_and_everything [error] {
  assert world.world_selection_argv(["xsh", "m4"], "")? == ["--root", "xsh", "--root", "m4"]
  assert world.world_selection_argv([], "pre-cmake")? == ["--all", "--without", "cmake", "--without", "linux"]
  assert world.world_selection_argv([], "")? == ["--all"]

  match world.world_selection_argv([], "pre-linux") {
    Ok(_) => test.fail("an unknown stop line was accepted")
    Err(problem) => assert "unknown stop line pre-linux" in problem.message
  }
}

test test_world_args_reject_ambiguous_or_incomplete_commands [error] {
  let build = world.parse_world_args(["build", "--arch", "aarch64", "--stop", "pre-cmake", "--jobs", "2"])?
  assert build.stop == "pre-cmake" and build.jobs == 2

  for argv in [
    ["build", "--arch", "aarch64", "--package", "xsh", "--stop", "pre-cmake"],
    ["publish", "--arch", "aarch64"],
    ["root", "--arch", "aarch64", "--repo", "http://127.0.0.1:3000"],
    ["build", "--stop", "pre-cmake"],
  ] {
    match world.parse_world_args(argv) {
      Ok(_) => test.fail(f"{argv.join(" ")} was accepted")
      Err(_) => {}
    }
  }
}

# Containers never get a network: the source cache arrives with the read-only
# checkout, and only host processes reach the loopback mirror.
test test_world_containers_are_offline_with_a_read_only_checkout [error] {
  let value = xsh_seed.xsh_seed_arch("aarch64")?
  let argv = world.world_container_argv(
    p"docker",
    /work/laputa,
    /s,
    value,
    "laputa-package-tools:aarch64-b",
    /work/laputa/.out/world/aarch64,
    /work/laputa/.out/artifacts/aarch64,
    {uid: 1000, gid: 1000},
    ["/bin/xsh", "pm.xsh"],
  )
  assert [item for item in argv if item == "--network"].len() == 1
  assert "none" in argv
  assert "linux/arm64" in argv
  assert "type=bind,src=/work/laputa,dst=/src/laputa,readonly" in argv
  assert "type=bind,src=/s/xsh,dst=/bin/xsh,readonly" in argv
  assert "type=bind,src=/work/laputa/.out/world/aarch64,dst=/output" in argv
  assert "type=bind,src=/work/laputa/.out/artifacts/aarch64,dst=/artifacts" in argv
  assert "type=bind,src=/work/laputa/.out/cache/linux-kbuild,dst=/var/cache/laputa/linux-kbuild" in argv
  assert ! (argv |> any .starts_with("XSH_PM_REPO"))
  assert argv[argv.len() - 2] == "/bin/xsh"
  # The command runs through the entry that hands the writable mounts back.
  assert "/src/laputa/seed/container_entry.xsh" in argv
  assert "1000" in argv
}

pure shell_word(item: Str) -> Str {
  if " " in item { f"\"{item}\"" } else { item }
}

# The words before and after the build image: Docker options, then the cargo command.
type ImageSplit = {docker: List[Str], cargo: List[Str]}

pure split_at_image(words: List[Str]) -> ImageSplit {
  var index = 0

  while index < words.len() {
    if words[index] == xsh_seed.xsh_seed_build_image {
      return {docker: words[..index], cargo: words[index + 1..]}
    }

    index += 1
  }

  {docker: words, cargo: []}
}

# `make host-xsh` builds the host tools with plain Docker because no XSH exists
# yet. It must stay the seed's cargo build for the host triple, or the two
# stop sharing `.out/xsh-target` and a Linux host compiles XSH twice.
test test_host_xsh_build_is_the_seed_cargo_build_for_the_host_arch [fs, process, error] {
  let laputa_root = fs.cwd()?

  for arch in ["aarch64", "x86_64"] {
    let host_arch = f"HOST_ARCH={arch}"
    let dry_run = run.text make -n --no-print-directory host-xsh HOST_OS=Linux $host_arch XSH_ROOT=/work/xsh ?
    let commands = dry_run.replace("\\\n", " ").lines() |> where "cargo build" in .
    assert commands.len() == 1
    let made = split_at_image(commands[0].words())
    let made_docker = made.docker.join(" ")

    let seed_argv = xsh_seed.xsh_seed_cargo_build_argv(
      p"docker",
      laputa_root,
      /work/xsh,
      xsh_seed.xsh_seed_arch(arch)?,
      4,
    )?
    let seed = split_at_image([shell_word(item) for item in seed_argv].join(" ").words())
    assert made.cargo == seed.cargo
    assert seed.cargo.len() > 0

    let seed_options = split_at_image(seed_argv).docker
    var index = 0
    while index + 1 < seed_options.len() {
      if seed_options[index] in ["--env", "--mount", "--platform", "--network"] {
        assert f"{seed_options[index]} {shell_word(seed_options[index + 1])}" in made_docker
      }

      index += 1
    }
  }
}
