##! Native-arm64 profile execution: one saved PM plan becomes verified artifacts, a runtime generation, and atomic image outputs.
#!/bin/xsh
use laputa.container_output as container_output
use laputa.image as image
# This one facade keeps PM's typed values inside the mounted package checkout.
# The installed `/usr/lib/pm` copy is deliberately not a candidate in this
# process: the published runner gives duplicate module identities distinct tags.
use pm.generation_adapter as pm_generation_adapter

# This script intentionally does not import `laputa.types` or `laputa.profile`.
# PM and Laputa each declare their supported-target tag; XSH's user-module runtime currently
# shares tag symbols, so the host validates SystemProfile and passes this narrow JSON DTO.
error ContainerBuildError = Failed(message: Str) : InvalidData

type ContainerProfileBuildRequest = {
  format: Str,
  name: Str,
  runtime_roots: List[Str],
  kernel_package: Str,
  kernel_path: Str,
  forbidden_packages: List[Str],
  forbidden_sonames: List[Str],
}

pure container_output_root() -> Path {
  p"/output"
}

pure container_request_path() -> Path {
  fp"${container_output_root()}/.build-request.json"
}

pure container_build_plan_path() -> Path {
  fp"${container_output_root()}/build-plan.json"
}

pure container_generation_plan_path() -> Path {
  fp"${container_output_root()}/generation-plan.json"
}

pure container_generation_receipt_path() -> Path {
  fp"${container_output_root()}/generation.json"
}

pure container_output_generation_parent() -> Path {
  fp"${container_output_root()}/generations"
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

pure container_package_root() -> Path {
  p"/src/packages"
}

pure container_kernel_output() -> Path {
  fp"${container_output_root()}/vmlinuz"
}

pure container_rootfs_output() -> Path {
  fp"${container_output_root()}/rootfs.ext4"
}

pure container_disk_output() -> Path {
  fp"${container_output_root()}/disk.img"
}

# `/output` is a host bind mount and may be case-folding (notably on macOS),
# while the target ext4 generation is case-sensitive.  Keep every mutable root,
# generation, and image path beneath the container-local temporary workspace;
# only final regular artifacts and JSON manifests cross this boundary.
pure container_work_build_plan(work: Path) -> Path {
  fp"${work}/build-plan.json"
}

pure container_work_generation_parent(work: Path) -> Path {
  fp"${work}/generations"
}

pure container_work_generation_plan(work: Path) -> Path {
  fp"${work}/generation-plan.json"
}

pure container_work_generation_receipt(work: Path) -> Path {
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

proc container_load_request() [fs, error] -> Result[ContainerProfileBuildRequest] {
  let value = json.read(container_request_path())?.require(ContainerProfileBuildRequest)?
  let profile_name = regex.compile("^[a-z0-9][a-z0-9-]*$")?

  if value.format != "laputa-profile-build-request-1" or ! profile_name.matches(value.name) {
    return Err(ContainerBuildError.Failed("invalid profile build request"))
  }

  if value.runtime_roots.len() == 0 or value.kernel_package == "" or value.kernel_path == "" or value.kernel_path.starts_with("/") or ".." in value.kernel_path.split("/") {
    return Err(ContainerBuildError.Failed("profile build request has invalid package or kernel fields"))
  }

  value
}

proc container_prepare_overlay(request: ContainerProfileBuildRequest, work: Path) [fs, error] -> Result[Path] {
  let source = container_overlay_root(request.name)
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

proc container_require_no_forbidden_sonames(root: Path, request: ContainerProfileBuildRequest) [fs, error] {
  for entry in fs.walk(root, hidden: true) {
    continue unless entry.kind == "file"

    match elf.inspect(entry.path) {
      Ok(info) => {
        if info.soname in request.forbidden_sonames {
          return Err(ContainerBuildError.Failed(f"generation provides forbidden SONAME ${info.soname}"))
        }

        for soname in info.needed {
          if soname in request.forbidden_sonames {
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

proc container_extract_kernel(build_plan: Path, request: ContainerProfileBuildRequest, output: Path) [fs, error] {
  pm_generation_adapter.generation_adapter_copy_manifest_file(
    build_plan,
    container_store_root(),
    request.kernel_package,
    fp"${request.kernel_path}",
    output,
  )?
}

proc container_build_images(root: Path, rootfs: Path, disk: Path) [fs, process, error] {
  image.image_write_rootfs(root, p"/src/packages/repo/laputa-fs/files/mkfs.ext4.xsh", rootfs)?
  image.write_disk(rootfs, disk)?
  image.verify_disk(disk, fs.metadata(rootfs)?.size)?
}

proc container_publish_execution(work: Path) [fs, error] {
  # A previous implementation placed generations below `/output`.  That tree
  # cannot represent all Linux target paths on a case-folding host, so remove
  # only this obsolete generated staging location after the local result has
  # passed every verification step.
  fs.remove(container_output_generation_parent(), missing_ok: true)?

  for item in [
    {source: container_work_generation_plan(work), output: container_generation_plan_path()},
    {source: container_work_generation_receipt(work), output: container_generation_receipt_path()},
    {source: container_work_kernel(work), output: container_kernel_output()},
    {source: container_work_rootfs(work), output: container_rootfs_output()},
    {source: container_work_disk(work), output: container_disk_output()},
  ] {
    container_output.publish_final_file(item.source, item.output)?
  }
}

proc container_execute_profile(request: ContainerProfileBuildRequest, jobs: Int) [fs, net, process, env, time, error] {
  let handle = fs.tempdir()?
  defer fs.close_root(handle)?
  let work = fs.root_path(handle)?
  let build_plan = container_stage_build_plan(work)?
  let overlay = container_prepare_overlay(request, work)?
  let generation = pm_generation_adapter.generation_adapter_execute_profile(
    build_plan,
    container_package_root(),
    container_store_root(),
    jobs,
    request.runtime_roots,
    request.name,
    overlay,
    container_work_generation_parent(work),
    container_work_generation_plan(work),
    container_work_generation_receipt(work),
    request.forbidden_packages,
  )?
  let root = generation.generation_root
  container_require_no_forbidden_sonames(root, request)?
  container_extract_kernel(build_plan, request, container_work_kernel(work))?
  container_build_images(root, container_work_rootfs(work), container_work_disk(work))?
  container_publish_execution(work)?
}

proc main(...argv: List[Str]) [fs, net, process, env, time, error] {
  if argv.len() != 3 or (argv[0] != "plan" and argv[0] != "build") {
    return Err(ContainerBuildError.Failed("usage: container_build <plan|build> <profile-name> <jobs>"))
  }

  let request = container_load_request()?
  if argv[1] != request.name {
    return Err(ContainerBuildError.Failed(f"requested profile ${argv[1]} does not match build request ${request.name}"))
  }
  let jobs = argv[2].parse_int()?
  if jobs < 1 {
    return Err(ContainerBuildError.Failed("jobs must be positive"))
  }

  if argv[0] == "plan" {
    let handle = fs.tempdir()?
    defer fs.close_root(handle)?
    let work = fs.root_path(handle)?
    let overlay = container_prepare_overlay(request, work)?
    pm_generation_adapter.generation_adapter_plan_profile(
      container_build_plan_path(),
      request.runtime_roots,
      request.name,
      overlay,
      container_work_generation_plan(work),
    )?
    container_output.publish_final_file(container_work_generation_plan(work), container_generation_plan_path())?
    return
  }

  container_execute_profile(request, jobs)?
}

main(@args)?
