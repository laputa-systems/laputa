##! Native-arm64 profile execution: one saved PM plan becomes verified artifacts, a runtime generation, and atomic image outputs.
#!/bin/xsh
use laputa.container_output as container_output
use laputa.image as image
use laputa.profile as system_profile
use laputa.types as types

error ContainerBuildError = Failed(message: Str) : InvalidData

pure container_output_root() -> Path {
  p"/output"
}

pure container_build_plan_path() -> Path {
  fp"${container_output_root()}/build-plan.json"
}

pure container_generation_plan_path() -> Path {
  fp"${container_output_root()}/generation-plan.json"
}

pure container_overlay_root(name: Str) -> Path {
  fp"/src/laputa/profiles/${name}"
}

pure container_guest_proof_source() -> Path {
  p"/src/laputa/guest/qemu-dwl-foot-proof.xsh"
}

pure container_store_root() -> Path {
  p"/artifacts"
}

pure container_source_cache_root() -> Path {
  p"/sources"
}

pure container_package_root() -> Path {
  p"/src/packages"
}

# `/output` is a host bind mount and may be case-folding (notably on macOS),
# while the target ext4 generation is case-sensitive.  Keep every mutable root,
# generation, and image path beneath the container-local temporary workspace;
# only one complete, verified system bundle crosses this boundary.
pure container_work_build_plan(work: Path) -> Path {
  fp"${work}/build-plan.json"
}

pure container_work_generation_plan(work: Path) -> Path {
  fp"${work}/generation-plan.json"
}

pure container_work_generation_manifest(work: Path) -> Path {
  fp"${work}/generation.json"
}

pure container_work_kernel(work: Path) -> Path {
  fp"${work}/vmlinuz"
}

pure container_work_rootfs(work: Path) -> Path {
  fp"${work}/rootfs.ext4"
}

pure container_work_disk(work: Path) -> Path {
  fp"${work}/disk.img"
}

proc container_load_profile(name: Str) [fs, error] -> Result[types.SystemProfile] {
  system_profile.load(name, p"/src/laputa/profiles")?
}

proc container_prepare_overlay(profile: types.SystemProfile, work: Path) [fs, error] -> Result[Path] {
  let source = container_overlay_root(profile.name)
  let overlay = fp"${work}/overlay"
  let guest_proof = container_guest_proof_source()

  if ! fs.exists(source)? or fs.metadata(source)?.kind != "dir" {
    return Err(ContainerBuildError.Failed(f"profile overlay is missing: ${source}"))
  }

  if ! fs.exists(guest_proof)? or fs.metadata(guest_proof)?.kind != "file" {
    return Err(ContainerBuildError.Failed(f"guest proof source is missing: ${guest_proof}"))
  }

  let _ = fs.copy_tree(source, overlay, parents: true, overwrite: true)?
  fs.install(guest_proof, fp"${overlay}/usr/lib/laputa/qemu-dwl-foot-proof.xsh", 0o755, parents: true, overwrite: true)?
  overlay
}

proc container_require_no_forbidden_sonames(root: Path, profile: types.SystemProfile) [fs, error] {
  for entry in fs.walk(root, hidden: true) {
    continue unless entry.kind == "file"

    match elf.inspect(entry.path) {
      Ok(info) => {
        if info.soname in profile.forbidden_sonames {
          return Err(ContainerBuildError.Failed(f"generation provides forbidden SONAME ${info.soname}"))
        }

        for soname in info.needed {
          if soname in profile.forbidden_sonames {
            return Err(ContainerBuildError.Failed(f"generation needs forbidden SONAME ${soname}"))
          }
        }
      }
      Err(_) => {}
    }
  }
}

proc container_stage_build_plan(work: Path) [fs, error] -> Result[Path] {
  let source = container_build_plan_path()
  let staged = container_work_build_plan(work)

  if ! fs.exists(source)? or fs.metadata(source)?.kind != "file" or fs.metadata(source)?.size <= 0 {
    return Err(ContainerBuildError.Failed(f"saved BuildPlan is missing or empty: ${source}"))
  }

  fs.copy(source, staged)?

  if hash.sha256(source)?.hex() != hash.sha256(staged)?.hex() {
    return Err(ContainerBuildError.Failed("container-local BuildPlan staging does not match the saved manifest"))
  }

  staged
}

pure container_pm_argv(args: List[Str]) -> List[Str] {
  ["/bin/xsh", "/src/packages/pm.xsh", "--"].extend(args)
}

proc container_pm(args: List[Str]) [fs, process, error] {
  let status = process.run(
    process.command_argv(
      p"/bin/xsh",
      container_pm_argv(args),
      p"/src/packages",
    ),
  )?

  if ! status.ok {
    return Err(ContainerBuildError.Failed(f"PM public command failed: ${args.join(" ")}; the mounted PM checkout may not support this command"))
  }
}

proc container_pm_repo_build(build_plan: Path, jobs: Int) [fs, net, process, env, time, error] {
  container_pm([
    "repo",
    "build",
    build_plan.display(),
    "--store",
    container_store_root().display(),
    "--source-cache",
    container_source_cache_root().display(),
    "--jobs",
    f"${jobs}",
  ])?
}

proc container_pm_generation_manifest(
  build_plan: Path,
  profile: types.SystemProfile,
  overlay: Path,
  output: Path,
) [fs, process, error] {
  var args = ["generation", "manifest", build_plan.display()]

  for package_name in profile.package_roots {
    args = args.extend(["--runtime-root", package_name])
  }

  args = args.extend([
    "--profile",
    profile.name,
    "--overlay",
    overlay.display(),
    "--output",
    output.display(),
  ])
  container_pm(args)?
}

proc container_pm_generation_compose(
  build_plan: Path,
  manifest: Path,
  overlay: Path,
  output: Path,
) [fs, process, error] {
  container_pm([
    "generation",
    "compose",
    build_plan.display(),
    "--manifest",
    manifest.display(),
    "--store",
    container_store_root().display(),
    "--overlay",
    overlay.display(),
    "--output",
    output.display(),
  ])?
}

# Extract only the profile-declared kernel from the exact artifact selected by the saved BuildPlan.
# Laputa owns no PM archive logic: the child PM process verifies and extracts the
# immutable artifact before this container can publish an image.
proc container_extract_kernel(build_plan: Path, profile: types.SystemProfile, output: Path) [fs, process, error] {
  container_pm([
    "store",
    "extract",
    build_plan.display(),
    "--store",
    container_store_root().display(),
    "--package",
    profile.kernel_package,
    "--path",
    profile.kernel_path.display(),
    "--output",
    output.display(),
  ])?

  if ! fs.exists(output)? or fs.metadata(output)?.kind != "file" or fs.metadata(output)?.size <= 0 {
    return Err(ContainerBuildError.Failed(f"PM did not extract profile kernel ${profile.kernel_path.display()}"))
  }
}

proc container_build_images(root: Path, rootfs: Path, disk: Path) [fs, process, error] {
  image.image_write_rootfs(root, p"/src/packages/repo/laputa-fs/files/mkfs.ext4.xsh", rootfs)?
  image.write_disk(rootfs, disk)?
  image.verify_disk(disk, fs.metadata(rootfs)?.size)?
}

proc container_system_key(build_plan: Path, generation_manifest: Path, profile: types.SystemProfile) [fs, error] -> Result[Str] {
  let manifest = json.read(generation_manifest)?.require(Record)?
  let generation_sha256: Str = manifest.get("generation_sha256")?
  let plan_value = json.read(build_plan)?.require(Record)?
  let nodes: List[Record] = plan_value.get("nodes")?
  var kernel_key = ""
  for node in nodes {
    let name: Str = node.get("name")?
    if name == profile.kernel_package {
      kernel_key = node.get("artifact_key")?
    }
  }
  if generation_sha256.count_chars() != 64 or kernel_key.count_chars() != 64 {
    return Err(ContainerBuildError.Failed("saved plan or generation manifest has an invalid system identity"))
  }
  bytes.from_text(f"laputa-qemu-system-1\ngeneration\t${generation_sha256}\nkernel\t${kernel_key}\nimage-format-epoch\t1\n").sha256().hex()
}

proc container_publish_execution(work: Path, profile: types.SystemProfile) [fs, error] {
  let key = container_system_key(container_work_build_plan(work), container_work_generation_manifest(work), profile)?
  container_output.publish_bundle(
    container_output_root(),
    key,
    [
      {name: "build-plan.json", source: container_work_build_plan(work)},
      {name: "generation.json", source: container_work_generation_manifest(work)},
      {name: "vmlinuz", source: container_work_kernel(work)},
      {name: "rootfs.ext4", source: container_work_rootfs(work)},
      {name: "disk.img", source: container_work_disk(work)},
    ],
  )?
}

proc container_execute_profile(profile: types.SystemProfile, jobs: Int) [fs, net, process, env, time, error] {
  let handle = fs.tempdir()?
  defer fs.close_root(handle)?
  let work = fs.root_path(handle)?
  let build_plan = container_stage_build_plan(work)?
  let overlay = container_prepare_overlay(profile, work)?
  container_pm_repo_build(build_plan, jobs)?
  container_pm_generation_manifest(
    build_plan,
    profile,
    overlay,
    container_work_generation_plan(work),
  )?
  container_pm_generation_compose(
    build_plan,
    container_work_generation_plan(work),
    overlay,
    fp"${work}/generation",
  )?
  let root = fp"${work}/generation"
  let embedded_manifest = fp"${root}/var/lib/laputa/generation.json"
  if ! fs.exists(embedded_manifest)? or fs.metadata(embedded_manifest)?.kind != "file" {
    return Err(ContainerBuildError.Failed("PM generation compose did not write /var/lib/laputa/generation.json"))
  }
  fs.copy(embedded_manifest, container_work_generation_manifest(work))?
  container_require_no_forbidden_sonames(root, profile)?
  container_extract_kernel(build_plan, profile, container_work_kernel(work))?
  container_build_images(root, container_work_rootfs(work), container_work_disk(work))?
  container_publish_execution(work, profile)?
}

proc main(...argv: List[Str]) [fs, net, process, env, time, error] {
  if argv.len() != 3 or (argv[0] != "plan" and argv[0] != "build") {
    return Err(ContainerBuildError.Failed("usage: container_build <plan|build> <profile-name> <jobs>"))
  }

  let profile = container_load_profile(argv[1])?
  let jobs = argv[2].parse_int()?
  if jobs < 1 {
    return Err(ContainerBuildError.Failed("jobs must be positive"))
  }

  if argv[0] == "plan" {
    let handle = fs.tempdir()?
    defer fs.close_root(handle)?
    let work = fs.root_path(handle)?
    let overlay = container_prepare_overlay(profile, work)?
    container_pm_generation_manifest(
      container_build_plan_path(),
      profile,
      overlay,
      container_work_generation_plan(work),
    )?
    container_output.publish_final_file(container_work_generation_plan(work), container_generation_plan_path())?
    return
  }

  container_execute_profile(profile, jobs)?
}

main(@args)?
