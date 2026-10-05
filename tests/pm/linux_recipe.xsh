##! Regression coverage for Linux recipe modules that must parse under the published runner.
use packages.linux.PKGBUILD-shared as linux_shared
use packages.linux.linux_config
use pm.build as pm_build
use pm.catalog
use pm.fingerprint
use pm.plan
use pm.policy
use pm.recipe
use pm.sources
use pm.types
use pm.util

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/linux-recipe/{name}"
}

proc runner() [fs, process, env, error] -> Result[Path] {
  let configured = (e"XSH_HOST" ?? "").trim()

  return path.absolute(fp"{configured}")? when configured != ""

  process.which("xsh")?
}

proc module_root() [fs, error] -> Result[Path] {
  path.absolute(p".")?
}

proc linux_config_source(pkg: types.Package) [error] -> Result[types.UpstreamSource] {
  for source in pkg.upstream_sources {
    return source when source.source.display().starts_with("files/config/aarch64/")
  }

  Err(types.PmError.PackageContract("linux is missing its aarch64 config input"))
}

test test_linux_kbuild_modules_parse_and_preserve_job_error_branch [fs, process, env, error] { |ctx|
  let stderr = test.temp_path(ctx, name: "linux-kbuild-jobs.err")
  let xsh = runner()?
  let modules = module_root()?
  let script = fixture("published-runner-shared.xsh")
  let success = run.status XSH_MODULE_PATH=$modules XSH_LINUX_KBUILD_JOBS="1" $xsh $script 2> $stderr ?
  assert success.ok
  let failure = run.status XSH_MODULE_PATH=$modules XSH_LINUX_KBUILD_JOBS="0" $xsh $script 2> $stderr ?
  assert failure.ok == false
  let observed_output_1 = stderr.read_text()?
  assert "linux-kbuild-jobs" in observed_output_1
}

test test_linux_config_fragment_is_explicit_staged_fingerprinted_input [fs, net, process, env, time, error] { |ctx|
  let original = recipe.load_package(p"packages/linux")?
  let config = linux_config_source(original)?
  let stage_root = test.temp_dir(ctx, name: "linux-config-stage")?
  let source = fp"{stage_root}/source"
  fs.mkdir(source)?
  sources.stage_package_sources({...original, upstream_sources: [config]}, source)?
  let staged = fp"{source}/.laputa-inputs/files/config/aarch64/base-aarch64.fragment"
  assert staged.exists()?

  let copied_root = test.temp_dir(ctx, name: "linux-config-fingerprint")?
  let copied = fp"{copied_root}/packages/linux"
  let _ = fs.copy_tree(p"packages/linux", copied, parents: true, overwrite: true)?
  let before = recipe.load_package(copied)?
  let first = fingerprint.package_build_input(copied_root, before, types.target_aarch64())?
  fs.write(fp"{copied}/files/config/aarch64/base-aarch64.fragment", "# changed staged config input\n")?
  let after = recipe.load_package(copied)?
  assert fingerprint.package_build_input(copied_root, after, types.target_aarch64())? == first == false
}

test test_linux_x86_generated_inputs_are_staged_at_build_source_root [fs, net, process, env, time, error] { |ctx|
  let original = recipe.load_package(p"packages/linux")?
  let required = [
    "timeconst.h",
    "cpufeaturemasks-x86.h",
    "rq-offsets.h",
    "inat-tables-x86.c",
    "x86-jump-label-patch.c",
  ]
  let local_sources = [
    input
    for input in original.upstream_sources
    if input.source.name in required
  ]
  assert local_sources.len() == required.len()

  let stage_root = test.temp_dir(ctx, name: "linux-x86-generated-inputs")?
  let source = fp"{stage_root}/source"
  fs.mkdir(source)?
  sources.stage_package_sources({...original, upstream_sources: local_sources}, source)?

  for name in required {
    test.ok(fs.exists(fp"{source}/{name}")?, f"missing staged {name}")?
  }
}

test test_laputa_pm_repository_inputs_stage_and_fingerprint_from_an_isolated_recipe [fs, net, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "laputa-pm-repository-input")?
  let package_dir = fp"{root}/packages/laputa-pm"
  let source = fp"{root}/source"
  let _ = fs.copy_tree(p"packages/laputa-pm", package_dir, parents: true, overwrite: true)?
  fs.copy(p"pm.xsh", fp"{root}/pm.xsh", overwrite: true)?
  let _ = fs.copy_tree(p"pm", fp"{root}/pm", parents: true, overwrite: true)?
  fs.mkdir(source)?
  let pkg = recipe.load_package(package_dir)?
  let first = fingerprint.package_build_input(root, pkg, types.target_aarch64())?

  env ({
    XSH_PM_REPOSITORY_ROOT: root.display(),
  }) {
    # `pkg.dir` intentionally points at an isolated recipe copy. Repository
    # inputs must still stage from the explicit repository root, not parent
    # traversal from that directory.
    sources.stage_package_sources(pkg, source)?
  } ?

  assert fs.exists(fp"{source}/pm.xsh")?
  assert fs.exists(fp"{source}/pm/execute.xsh")?
  fs.write(fp"{root}/pm/execute.xsh", "changed PM executor input\n")?
  let second = fingerprint.package_build_input(root, pkg, types.target_aarch64())?
  assert second == first == false
}

test test_baselayout_directory_input_stages_into_the_prepared_source_root [fs, net, process, env, time, error] { |ctx|
  let pkg = recipe.load_package(p"packages/baselayout")?
  let root = test.temp_dir(ctx, name: "baselayout-directory-input")?
  let source = fp"{root}/source"
  fs.mkdir(source)?

  sources.stage_package_sources(pkg, source)?

  assert fs.exists(fp"{source}/etc/passwd")?
  assert fs.exists(fp"{source}/usr/lib/init/rc.boot")?
}

test test_checkout_directory_input_stages_with_checkout_modes [fs, net, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "baselayout-checkout-modes")?
  let package_dir = fp"{root}/baselayout"
  let source = fp"{root}/source"
  let _ = fs.copy_tree(p"packages/baselayout", package_dir, parents: true, overwrite: true)?
  # A checkout below a setgid directory, under a group-writable umask.
  fs.chmod(fp"{package_dir}/files/rootfs/usr", 0o2775)?
  fs.chmod(fp"{package_dir}/files/rootfs/etc/passwd", 0o664)?
  fs.mkdir(source)?

  sources.stage_package_sources(recipe.load_package(package_dir)?, source)?

  assert fs.metadata(fp"{source}/usr")?.mode % 4096 == 0o755
  assert fs.metadata(fp"{source}/etc/passwd")?.mode % 4096 == 0o644
  assert fs.metadata(fp"{source}/usr/lib/init/rc.boot")?.mode % 4096 == 0o755
}

test test_baselayout_declares_boot_mount_directories_as_payload [fs, env, error] { |ctx|
  let pkg = recipe.load_package(p"packages/baselayout")?
  let trees = [entry.path.display() for entry in pkg.filetree if entry.kind == types.file_kind_tree()]

  # The kernel mounts devtmpfs before `/init`; the remaining mount points must
  # also be present before rc.boot performs its explicit mounts and fstab pass.
  for required in ["dev", "dev/pts", "dev/shm", "proc", "run", "sys", "tmp"] {
    assert required in trees
  }
}

test test_baselayout_build_materializes_empty_boot_mount_directories [fs, net, process, env, time, error] { |ctx|
  let pkg = recipe.load_package(p"packages/baselayout")?
  let root = test.temp_dir(ctx, name: "baselayout-empty-directories")?
  let source = fp"{root}/source"
  let dest = fp"{root}/dest"
  fs.mkdir(source)?
  sources.stage_package_sources(pkg, source)?
  recipe.call_build(pkg, source, dest)?

  for required in ["dev", "dev/pts", "dev/shm", "proc", "run", "sys", "tmp"] {
    assert fs.metadata(fp"{dest}/{required}")?.kind == "dir"
  }
}

test test_laputa_net_hook_directories_are_empty_package_payload [fs, net, process, env, time, error] { |ctx|
  let pkg = recipe.load_package(p"packages/laputa-net")?
  let root = test.temp_dir(ctx, name: "laputa-net-hook-directories")?
  let source = fp"{root}/source"
  let dest = fp"{root}/dest"
  fs.mkdir(source)?
  sources.stage_package_sources(pkg, source)?
  recipe.call_build(pkg, source, dest)?

  for hook in ["if-pre-up.d", "if-up.d", "if-down.d", "if-pre-down.d", "if-post-down.d"] {
    let relative = fp"etc/network/{hook}"
    assert {path: relative, kind: types.file_kind_tree()} in pkg.filetree
    assert fs.metadata(fp"{dest}/{relative}")?.kind == "dir"
    for entry in fs.children(fp"{dest}/{relative}")? {
      test.fail(f"network hook directory contains {entry.name}")?
    }
  }
}

test test_baselayout_artifact_archives_empty_boot_mount_directories [fs, net, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "baselayout-artifact-directories")?
  let recipe_dir = fp"{root}/recipe"
  let source = fp"{root}/source"
  let dest = fp"{root}/dest"
  let archive_path = fp"{root}/baselayout.tar.gz"
  let extracted = fp"{root}/extracted"
  let _ = fs.copy_tree(p"packages/baselayout", recipe_dir, parents: true, overwrite: true)?
  fs.mkdir(source)?
  let pkg = recipe.load_package(recipe_dir)?
  sources.stage_package_sources(pkg, source)?
  pm_build.build_prepared_package(recipe_dir, source, dest, archive_path)?

  if ! fs.exists(fp"{dest}/dev")? {
    test.fail("baselayout prepared payload is missing dev")?
  }

  archive.tar_extract(archive_path, extracted)?

  for required in ["dev", "dev/pts", "dev/shm", "proc", "run", "sys", "tmp"] {
    if ! fs.exists(fp"{extracted}/{required}")? {
      test.fail(f"baselayout archive is missing {required}")?
    }

    assert fs.metadata(fp"{extracted}/{required}")?.kind == "dir"
  }
}

test test_xsh_proof_uses_declared_usr_bin_runners_without_baselayout [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "xsh-proof-runtime-closure")?
  let stderr = fp"{root}/xsh-proof.stderr"
  let modules = module_root()?
  let xsh = runner()?
  fs.mkdir(fp"{root}/usr/bin")?
  fs.mkdir(fp"{root}/usr/lib/xsh/core")?
  fs.mkdir(fp"{root}/var/lib/xsh-pm/packages/xsh")?

  for path_value in [
    fp"{root}/usr/bin/sh",
    fp"{root}/usr/bin/xsh",
    fp"{root}/usr/bin/xshi",
    fp"{root}/usr/bin/xsht",
    fp"{root}/usr/bin/cat",
    fp"{root}/usr/bin/ifup",
    fp"{root}/usr/bin/env",
    fp"{root}/usr/lib/xsh/core/cat",
  ] {
    fs.write(path_value, "typed xsh proof fixture\n")?
  }

  fs.write(fp"{root}/var/lib/xsh-pm/packages/xsh/metadata.json", "{}\n")?
  let status = process.run(
    process.command_argv(
      xsh,
      [xsh, "packages/xsh/proof.xsh", "--", root],
      cwd: modules,
      env: {XSH_MODULE_PATH: modules},
      stderr:,
    ),
  )?
  if ! status.ok {
    test.fail(stderr.read_text()?)?
  }
}

test test_wlroots_declares_the_runtime_seatd_provider [fs, env, error] { |ctx|
  let pkg = recipe.load_package(p"packages/wlroots0.20")?
  assert "seatd" in pkg.deps
}

# Planning the real repository keys the `xsh` package by the local XSH seed, a
# derived input under `.out/` that only `make seed` produces. Plan a disposable
# root that shares the checked-in recipes and repository inputs and holds a
# fixture seed instead.
proc repository_with_fixture_seed(ctx: TestContext) [fs, error] -> Result[Path] {
  let checkout = fs.cwd()?
  let root = test.temp_dir(ctx, name: "repository-with-seed")?

  for name in ["packages", "pm", "pm.xsh", "xinit"] {
    fs.symlink(fp"{checkout}/{name}", fp"{root}/{name}")?
  }

  let seed = fp"{root}/.out/seed/aarch64"
  fs.mkdir(seed)?

  for name in ["xsh", "xshi", "xsht", "core.tar.xz", "manifest.json"] {
    fs.write(fp"{seed}/{name}", f"fixture {name}\n")?
  }

  root
}

test test_wlroots_plan_carries_seatd_as_a_runtime_edge [fs, env, error] { |ctx|
  let catalog_value = catalog.load(repository_with_fixture_seed(ctx)?)?
  let plan_value = plan.resolve(
    catalog_value,
    {target: types.target_aarch64(), index_sha256: "linux-recipe-empty-remote", packages: []},
    policy.aarch64_docker(),
    ["wlroots0.20"],
    false,
  )?
  var found = false
  for node in plan_value.nodes {
    continue unless node.name == "wlroots0.20"
    for dependency in node.dependencies {
      if dependency.name == "seatd" {
        assert dependency.kind == types.dependency_runtime()
        found = true
      }
    }
  }

  assert found
}

test test_linux_config_resolves_staged_fragment_from_isolated_cwd_and_rejects_missing [fs, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-config-resolve")?
  let source = fp"{root}/source"
  let staged = fp"{source}/.laputa-inputs/files/config/aarch64/base-aarch64.fragment"
  let recipe_root = fp"{root}/recipe"
  let unrelated = fp"{root}/unrelated"
  fs.mkdir(staged.parent)?
  fs.mkdir(recipe_root)?
  fs.mkdir(unrelated)?
  fs.write(staged, "CONFIG_LAPUTA_STAGE=y\n")?

  env ({
    XSH_PM_SOURCE_DIR: source.display(),
    XSH_PM_RECIPE_DIR: recipe_root.display(),
  }) {
    cd unrelated {
      let resolved = linux_config.resolve_config_fragments([p"files/config/aarch64/base-aarch64.fragment"])?
      assert resolved == [staged]
    } ?
  }?

  fs.remove(staged)?

  env ({
    XSH_PM_SOURCE_DIR: source.display(),
    XSH_PM_RECIPE_DIR: recipe_root.display(),
  }) {
    match linux_config.resolve_config_fragments([p"files/config/aarch64/base-aarch64.fragment"]) {
      Ok(_) => test.fail("missing staged Linux config fragment unexpectedly resolved")?
      Err(error) => assert "missing kernel config fragment files/config/aarch64/base-aarch64.fragment" in error.message
    }
  }?
}

test test_linux_discovery_pool_executes_worker_from_staged_recipe [fs, process, env, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "linux-staged-discovery-worker")?
  let recipe_root = fp"{root}/recipe"
  let source = fp"{root}/source"
  let worker = fp"{recipe_root}/kbuild-pool-worker.xsh"
  let _ = fs.copy_tree(p"packages/linux", recipe_root, parents: true, overwrite: true)?
  fs.mkdir(source)?
  fs.write(fp"{source}/.config", "")?
  fs.write(fp"{source}/Kbuild", "obj-y += one.o\n")?
  assert worker.exists()?

  env ({
    XSH_PM_SOURCE_DIR: source.display(),
    XSH_PM_RECIPE_DIR: recipe_root.display(),
    XSH_LINUX_KBUILD_DISCOVER_JOBS: "1",
  }) {
    cd source {
      let plan = linux_shared.discover_package_plan("arm64")?
      assert p"one.o" in plan.objects
    } ?
  }?
}
