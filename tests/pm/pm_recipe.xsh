##! Behavior coverage for the typed package-recipe boundary.
use pm.catalog
use pm.recipe
use pm.sources
use pm.types
use pm.target
use pm.util

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/{name}"
}

proc expect_contract_rejection(dir: Path, description: Str) {
  match recipe.load_package(dir) {
    Ok(_) => test.fail(f"{description}: recipe unexpectedly loaded")
    Err(error) => test.ok(error.message != "", f"{description}: error has a message")
  }
}

proc assert_local_source_checksums(package: Str) {
  let package_dir = fp"packages/{package}"
  let pkg = recipe.load_package(package_dir)?

  for source in pkg.upstream_sources {
    let raw = source.source.display()
    continue unless raw.starts_with("files/")
    let staged = fp"packages/{package}/{raw}"
    let expected = sources.source_checksum(source, "aarch64")?
    assert hash.sha256(staged)?.hex() == expected
  }
}

test test_recipe_loads_valid_payload_with_relative_skip_checksum [fs, env, error] {
  let pkg = recipe.load_package(fixture("recipe-valid-payload"))?
  assert pkg.kind == types.Payload
  assert pkg.upstream_sources.len() == 1
  assert pkg.upstream_sources[0].kind == types.Auto
  assert pkg.upstream_sources[0].checksums[0].sha256 == "SKIP"
  assert pkg.filetree[0].kind == types.File
}

test test_recipe_loads_valid_metapackage [fs, env, error] {
  let pkg = recipe.load_package(fixture("recipe-valid-meta"))?
  assert pkg.kind == types.Meta
  test.eq(pkg.filetree, [])
}

test test_recipe_loads_linux_metadata_without_kbuild_dynamic_import [fs, env, error] {
  let pkg = recipe.load_package(p"packages/linux")?
  assert pkg.name == "linux"
  assert pkg.ver == "7.2.9"
  assert pkg.kind == types.Payload
}

test test_ca_certificates_local_sources_match_declared_checksums [fs, env, error] {
  assert_local_source_checksums("ca-certificates")
}

test test_bison_local_source_matches_declared_checksum [fs, env, error] {
  assert_local_source_checksums("bison")
}

test test_flex_local_source_matches_declared_checksum [fs, env, error] {
  assert_local_source_checksums("flex")
}

test test_recipe_selects_target_filetree_variant [fs, env, error] {
  let x86 = recipe.load_package_for_target(p"packages/musl", types.target_x86_64())?
  let arm = recipe.load_package_for_target(p"packages/musl", types.target_aarch64())?
  let x86_filetree = [entry.path.display() for entry in x86.filetree].join("\n")
  let arm_filetree = [entry.path.display() for entry in arm.filetree].join("\n")
  assert "usr/lib/ld-musl-x86_64.so.1" in x86_filetree
  assert "usr/lib/ld-musl-aarch64.so.1" not in x86_filetree
  assert "usr/lib/ld-musl-aarch64.so.1" in arm_filetree
}

test test_recipe_rejects_invalid_package_name [fs, env, error] {
  expect_contract_rejection(fixture("recipe-invalid-name"), "invalid package name")
}

test test_recipe_rejects_production_directory_name_mismatch [fs, env, error] { |ctx|
  let repo_root = test.temp_dir(ctx, name: "recipe-repo")?
  let dir = fp"{repo_root}/packages/recipe-dir-mismatch"
  let _ = fs.copy_tree(fixture("recipe-dir-mismatch"), dir, parents: true, overwrite: true)?
  expect_contract_rejection(dir, "production directory/name mismatch")
}

test test_recipe_rejects_duplicate_dependency [fs, env, error] {
  expect_contract_rejection(fixture("recipe-duplicate-dependency"), "duplicate dependency")
}

test test_recipe_rejects_self_dependency [fs, env, error] {
  expect_contract_rejection(fixture("recipe-self-dependency"), "self dependency")
}

test test_recipe_rejects_invalid_source_kind [fs, env, error] {
  expect_contract_rejection(fixture("recipe-invalid-source-kind"), "invalid source kind")
}

test test_recipe_rejects_cargo_vendor_source_without_a_destination [fs, env, error] {
  match recipe.load_package(fixture("recipe-cargo-vendor-no-dest")) {
    Ok(_) => test.fail("a crate set staged over the source root was accepted")
    Err(problem) => assert "needs a `=> DIR` destination" in problem.message
  }
}

test test_recipe_rejects_invalid_file_kind [fs, env, error] {
  expect_contract_rejection(fixture("recipe-invalid-file-kind"), "invalid file kind")
}

test test_recipe_rejects_remote_skip_checksum [fs, env, error] {
  expect_contract_rejection(fixture("recipe-remote-skip"), "remote SKIP checksum")
}

test test_recipe_rejects_absolute_local_skip_checksum [fs, env, error] {
  expect_contract_rejection(fixture("recipe-absolute-skip"), "absolute local SKIP checksum")
}

test test_recipe_rejects_missing_aarch64_checksum [fs, env, error] {
  expect_contract_rejection(fixture("recipe-missing-aarch64-checksum"), "missing aarch64 checksum")
}

test test_recipe_rejects_duplicate_filetree_path [fs, env, error] {
  expect_contract_rejection(fixture("recipe-duplicate-filetree"), "duplicate filetree path")
}

test test_recipe_rejects_absolute_filetree_path [fs, env, error] {
  expect_contract_rejection(fixture("recipe-absolute-filetree"), "absolute filetree path")
}

test test_recipe_rejects_parent_filetree_traversal [fs, env, error] {
  expect_contract_rejection(fixture("recipe-parent-filetree"), "parent filetree traversal")
}

test test_recipe_rejects_payload_without_build [fs, env, error] {
  expect_contract_rejection(fixture("recipe-payload-no-build"), "payload without build")
}

test test_recipe_rejects_payload_without_proof [fs, env, error] {
  expect_contract_rejection(fixture("recipe-payload-no-proof"), "payload without proof")
}

test test_recipe_rejects_metapackage_with_payload_files [fs, env, error] {
  expect_contract_rejection(fixture("recipe-meta-payload-files"), "metapackage with payload files")
}

test test_recipe_loads_every_migrated_production_recipe [fs, env, error] {
  for entry in fs.children(p"packages")? {
    continue unless entry.kind == "dir"
    let pkg = recipe.load_package(entry.path)?
    assert pkg.name == entry.name
  }
}

test test_cargo_proof_accepts_rust_std_at_declared_lib_path [fs, process, env, error] { |ctx|
  guard system.uname()?.sysname == "Linux" else {
    test.skip("cargo's ELF proof runs in the pinned Linux build environment")
    return
  }

  # The host xsh stands in for cargo and rustc, so the target is the host's
  # arch and the build arch is the other one, which keeps the proof on its
  # cross-built path.
  let target_arch = util.normalize_arch(system.uname()?.machine)
  let build_arch = if target_arch == "aarch64" { "x86_64" } else { "aarch64" }
  let root = test.temp_dir(ctx, name: "cargo-proof-root")?
  let xsh = process.which("xsh")?
  fs.install(xsh, fp"{root}/usr/bin/cargo", 0o755, parents: true, overwrite: true)
  fs.install(xsh, fp"{root}/usr/bin/rustc", 0o755, parents: true, overwrite: true)
  fs.mkdir(fp"{root}/usr/lib/rustlib/{target_arch}-unknown-linux-musl/lib")
  let stderr_path = test.temp_path(ctx, name: "cargo-proof-stderr")
  let status = process.run(
    process.command_argv(
      xsh,
      ["xsh", "packages/cargo/proof.xsh", "--", root],
      fs.cwd()?,
      {XSH_PM_BUILD_ARCH: build_arch, XSH_PM_TARGET_ARCH: target_arch},
      stderr: stderr_path,
    ),
  )?
  test.ok(status.ok, fs.read_text(stderr_path)?)
}

# A stand-in executable that prints `output` only when run against the proof
# root's libraries, and aborts otherwise.
proc write_wpa_tool(xsh: Path, root: Path, name: Str, output: Str) {
  let bin = fp"{root}/usr/bin/{name}"
  fs.write(
    bin,
    f"""#!{xsh}
proc main(...argv: List[Str]) [env, error] {{
  if ! (env.get("LD_LIBRARY_PATH") ?? "").starts_with("{root}/usr/lib") {{
    abort(3)
  }}
  print "{output}"
}}
main(@args)?
""", mode: 0o755,
  )
}

type WpaProofRun = {ok: Bool, stderr: Str}

proc run_wpa_proof(ctx: TestContext, name: Str, psk: Str) [fs, process, env, error] -> Result[WpaProofRun] {
  let root = test.temp_dir(ctx, name:)?
  let xsh = process.which("xsh")?
  fs.mkdir(fp"{root}/usr/bin")
  fs.mkdir(fp"{root}/usr/lib/xinit/services")
  fs.mkdir(fp"{root}/etc/wpa_supplicant")
  fs.mkdir(fp"{root}/var/lib/xsh-pm/packages/wpa_supplicant")
  write_wpa_tool(xsh, root, "wpa_supplicant", "wpa_supplicant v2.12")
  write_wpa_tool(xsh, root, "wpa_passphrase", f"psk={psk}")
  fs.write(fp"{root}/usr/bin/wpa_cli", "")
  fs.write(fp"{root}/usr/lib/xinit/services/wpa_supplicant.xsh", "")
  fs.write(fp"{root}/etc/wpa_supplicant/wpa_supplicant.conf", "")
  fs.write(fp"{root}/var/lib/xsh-pm/packages/wpa_supplicant/metadata.json", "{}")
  let stderr_path = test.temp_path(ctx, name: f"{name}-stderr")
  let status = process.run(
    process.command_argv(
      xsh,
      ["xsh", "packages/wpa_supplicant/proof.xsh", "--", root],
      fs.cwd()?,
      {},
      stderr: stderr_path,
    ),
  )?
  {ok: status.ok, stderr: fs.read_text(stderr_path)?}
}

test test_wpa_proof_runs_binaries_with_composed_libraries [fs, process, env, error] { |ctx|
  guard system.uname()?.sysname == "Linux" else {
    test.skip("the WPA proof runs a Linux executable")
    return
  }

  let good = run_wpa_proof(ctx, "wpa-proof-good", "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e")?
  test.ok(good.ok, good.stderr)

  let bad = run_wpa_proof(ctx, "wpa-proof-bad-psk", "00")?
  assert ! bad.ok
  assert "wrong PSK" in bad.stderr
}

proc write_runtime_only_recipe(ctx: TestContext, name: Str, dependencies: Str) -> Result[Path] {
  let dir = test.temp_dir(ctx, name:)?
  let documented = dependencies.replace("export let ", "## Fixture export.\nexport let ")
  fs.write(
    fp"{dir}/PKGBUILD.xsh",
    f"""##! Runtime-only dependency fixture recipe.
## Fixture export.
export let name = "runtime-only-probe"
## Fixture export.
export let package_kind = "meta"
## Fixture export.
export let ver = "1"
## Fixture export.
export let rel = "1"
{documented}
## Fixture export.
export let upstream_sources = []
## Fixture export.
export let filetree = []
""",
  )
  dir
}

test test_recipe_runtime_only_deps_load_and_never_repeat_a_build_dependency [fs, env, error] { |ctx|
  let valid = write_runtime_only_recipe(
    ctx,
    "runtime-only-valid",
    "export let deps = [\"lib\"]\nexport let mkdeps_host = [\"tool\"]\nexport let runtime_only_deps = [\"service\"]",
  )?
  let pkg = recipe.load_package(valid)?
  assert pkg.runtime_only_deps == ["service"]
  assert pkg.deps == ["lib"]

  let omitted = write_runtime_only_recipe(
    ctx,
    "runtime-only-omitted",
    "export let deps = []\nexport let mkdeps_host = []",
  )?
  test.eq(recipe.load_package(omitted)?.runtime_only_deps, [])

  for overlap in [
    "export let deps = [\"lib\"]\nexport let mkdeps_host = []\nexport let runtime_only_deps = [\"lib\"]",
    "export let deps = []\nexport let mkdeps_host = [\"lib\"]\nexport let runtime_only_deps = [\"lib\"]",
    "export let deps = []\nexport let mkdeps_host = []\nexport let mkdeps_target = [\"lib\"]\nexport let runtime_only_deps = [\"lib\"]",
  ] {
    let dir = write_runtime_only_recipe(ctx, "runtime-only-overlap", overlap)?

    match recipe.load_package(dir) {
      Ok(_) => test.fail("runtime-only dependency repeating a build dependency unexpectedly loaded")
      Err(problem) => assert "runtime_only_deps entry lib is also a build dependency" in problem.message
    }
  }

  let repeated = write_runtime_only_recipe(
    ctx,
    "runtime-only-repeated",
    "export let deps = []\nexport let mkdeps_host = []\nexport let runtime_only_deps = [\"service\", \"service\"]",
  )?

  match recipe.load_package(repeated) {
    Ok(_) => test.fail("repeated runtime-only dependency unexpectedly loaded")
    Err(problem) => assert "runtime_only_deps contains duplicate dependency service" in problem.message
  }
}

# musl's arch/*/bits/alltypes.h.in: aarch64 declares `unsigned wchar_t`,
# x86_64 `int wchar_t`; gnulib-configured packages (bison) take this table.
test test_musl_abi_follows_each_arch_wchar_t_signedness [error] {
  let arm = target.lp64_musl_abi("aarch64")
  assert ! arm.signed_wchar_t
  assert arm.wchar_t_suffix == "\"UINT\""
  let x86 = target.lp64_musl_abi("x86_64")
  assert x86.signed_wchar_t
  assert x86.wchar_t_suffix == "\"INT\""
}

# Writes a metapackage recipe into `repo`'s packages directory. `extra` is
# appended exports, such as an `architectures` list.
proc write_arch_recipe(repo: Path, name: Str, deps: Str, extra: Str) -> Result[Path] {
  let dir = fp"{repo}/packages/{name}"
  fs.mkdir(dir)
  fs.write(
    fp"{dir}/PKGBUILD.xsh",
    f"""##! Package architecture fixture recipe.
## Fixture export.
export let name = "{name}"
## Fixture export.
export let package_kind = "meta"
## Fixture export.
export let ver = "1"
## Fixture export.
export let rel = "1"
## Fixture export.
export let deps = {deps}
## Fixture export.
export let mkdeps_host = []
## Fixture export.
export let upstream_sources = []
## Fixture export.
export let filetree = []
{extra}
""",
  )
  dir
}

test test_recipe_architectures_default_to_every_target_and_reject_invalid_lists [fs, env, error] { |ctx|
  let repo = test.temp_dir(ctx, name: "recipe-architectures")?
  let omitted = write_arch_recipe(repo, "arch-omitted", "[]", "")?
  assert recipe.load_package(omitted)?.architectures == ["aarch64", "x86_64"]

  let x86_only = write_arch_recipe(repo, "arch-x86-only", "[]", "## Fixture export.\nexport let architectures = [\"x86_64\"]")?
  assert recipe.load_package_for_target(x86_only, types.target_aarch64())?.architectures == ["x86_64"]

  for case in [
    {list: "[]", message: "architectures must name at least one target architecture"},
    {list: "[\"all\"]", message: "architectures has unsupported architecture all"},
    {list: "[\"x86_64\", \"x86_64\"]", message: "architectures repeats x86_64"},
  ] {
    let dir = write_arch_recipe(
      test.temp_dir(ctx, name: "recipe-architectures-invalid")?,
      "arch-invalid",
      "[]",
      f"## Fixture export.\nexport let architectures = {case.list}",
    )?

    match recipe.load_package(dir) {
      Ok(_) => test.fail(f"architectures {case.list} unexpectedly loaded")
      Err(problem) => assert case.message in problem.message
    }
  }
}

test test_catalog_omits_a_package_outside_its_architectures_and_rejects_its_dependents [fs, env, error] { |ctx|
  let repo = test.temp_dir(ctx, name: "catalog-architectures")?
  let _ = write_arch_recipe(repo, "x86-firmware", "[]", "## Fixture export.\nexport let architectures = [\"x86_64\"]")?
  let _ = write_arch_recipe(repo, "everywhere", "[]", "")?

  assert catalog.package_names(catalog.load_for_target(repo, types.target_x86_64())?) == ["everywhere", "x86-firmware"]
  assert catalog.package_names(catalog.load_for_target(repo, types.target_aarch64())?) == ["everywhere"]

  let _ = write_arch_recipe(repo, "needs-firmware", "[\"x86-firmware\"]", "")?
  assert catalog.load_for_target(repo, types.target_x86_64())?.packages.len() == 3

  match catalog.load_for_target(repo, types.target_aarch64()) {
    Ok(_) => test.fail("a dependency on an x86_64-only package unexpectedly loaded for aarch64")
    Err(problem) => assert "needs-firmware depends on x86-firmware, which does not exist for aarch64" in problem.message
  }
}
