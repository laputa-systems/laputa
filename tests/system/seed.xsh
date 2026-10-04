##! Behavior coverage for the local XSH seed and the content-keyed Laputa images.
use seed.images as images
use seed.xsh_seed as xsh_seed

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

proc write_seed(ctx: TestContext) [fs, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name: "seed-root")?
  let seed = xsh_seed.xsh_seed_dir(root, "aarch64")
  fs.mkdir(fp"${seed}/core")?
  var files: Map[Str] = {}

  for name in ["xsh", "xshi", "xsht", "core.tar.xz"] {
    fs.write(fp"${seed}/${name}", f"${name} bytes\n")?
    files[name] = hash.sha256(fp"${seed}/${name}")?.hex()
  }

  json.write(xsh_seed.xsh_seed_manifest_path(root, "aarch64"), {format: "laputa-xsh-seed-1", files})?
  root
}

test test_seed_require_accepts_a_seed_matching_its_manifest [fs, error] { |ctx|
  let root = write_seed(ctx)?
  assert xsh_seed.xsh_seed_require(root, "aarch64")? == xsh_seed.xsh_seed_dir(root, "aarch64")
}

test test_seed_require_rejects_a_missing_seed [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "no-seed")?

  match xsh_seed.xsh_seed_require(root, "aarch64") {
    Ok(_) => test.fail("a missing seed was accepted")?
    Err(problem) => assert "make seed" in problem.message
  }
}

test test_seed_require_rejects_a_product_that_differs_from_its_manifest [fs, error] { |ctx|
  let root = write_seed(ctx)?
  fs.write(fp"${xsh_seed.xsh_seed_dir(root, "aarch64")}/xshi", "a different build\n")?

  match xsh_seed.xsh_seed_require(root, "aarch64") {
    Ok(_) => test.fail("a mismatched seed product was accepted")?
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

proc image_fixture(ctx: TestContext) [fs, error] -> Result[Path] {
  let root = test.temp_dir(ctx, name: "images")?
  fs.mkdir(fp"${root}/seed")?
  fs.mkdir(fp"${root}/pm")?
  fs.mkdir(fp"${root}/packages/llvm-toolchain")?
  fs.write(fp"${root}/seed/Dockerfile.host-tools", "FROM alpine\n")?
  fs.write(fp"${root}/Dockerfile.package-tools", "FROM base\n")?
  fs.write(fp"${root}/bootstrap-llvm-seed.xsh", "seed helper\n")?
  fs.write(fp"${root}/packages/llvm-toolchain/PKGBUILD.xsh", "llvm recipe\n")?
  fs.write(fp"${root}/pm/cli.xsh", "pm module\n")?
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
  fs.write(fp"${root}/pm/cli.xsh", "changed pm module\n")?
  assert images.package_tools_tag(root, value)? == tools
  assert images.host_tools_tag(root, value)? == host

  fs.write(fp"${root}/packages/llvm-toolchain/PKGBUILD.xsh", "changed llvm recipe\n")?
  assert images.package_tools_tag(root, value)? != tools
  assert images.host_tools_tag(root, value)? == host

  fs.write(fp"${root}/seed/Dockerfile.host-tools", "FROM alpine\nRUN true\n")?
  assert images.host_tools_tag(root, value)? != host
}

test test_package_tools_requires_its_dockerfile [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "images-missing")?
  fs.mkdir(fp"${root}/seed")?
  fs.write(fp"${root}/seed/Dockerfile.host-tools", "FROM alpine\n")?

  match images.package_tools_tag(root, xsh_seed.xsh_seed_arch("aarch64")?) {
    Ok(_) => test.fail("a missing Dockerfile.package-tools was accepted")?
    Err(problem) => assert "Dockerfile.package-tools" in problem.message
  }
}

test test_package_tools_build_is_offline_and_native [error] {
  let value = xsh_seed.xsh_seed_arch("aarch64")?
  let argv = images.package_tools_build_argv(p"docker", /work/laputa, value, "laputa-host-tools:aarch64-a", "laputa-package-tools:aarch64-b", /work/laputa/.out/package-tools/aarch64/sources)
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
