##! Native-arm64 profile execution: one saved PM plan becomes verified artifacts, a runtime generation, and atomic image outputs.
#!/bin/xsh
use laputa.image as image
use pm.execute as pm_execute
use pm.generation as pm_generation
use pm.plan_json as pm_plan_json
use pm.remote as pm_remote
use pm.store as pm_store
use pm.types as pm_types

## This script intentionally does not import `laputa.types` or `laputa.profile`.
## PM and Laputa each declare their supported-target tag; XSH's user-module runtime currently
## shares tag symbols, so the host validates SystemProfile and passes this narrow JSON DTO.
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

type ContainerGenerationArtifactDto = {package_name: Str, package_id: Str, artifact_key: Str}

type ContainerGenerationPlanDto = {
  format: Str,
  target: Str,
  build_plan_sha256: Str,
  profile: Str,
  overlay_sha256: Str,
  replacements: List[Str],
  runtime_roots: List[Str],
  artifacts: List[ContainerGenerationArtifactDto],
  generation_sha256: Str,
}

type ContainerArtifactMetadataFileDto = {path: Str, kind: Str, mode: Int, sha256: Str, target: Str}
type ContainerArtifactMetadataDto = {name: Str, ver: Str, rel: Str, package_kind: Str, files: List[ContainerArtifactMetadataFileDto]}

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

pure container_generation_root(key: Str) -> Path {
  fp"${container_output_root()}/generations/${key}"
}

pure container_overlay_root(name: Str) -> Path {
  fp"/src/laputa/profiles/${name}"
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

pure container_generation_plan_dto(value: pm_types.GenerationPlan) -> ContainerGenerationPlanDto {
  {
    format: value.format,
    target: pm_types.target_text(value.target),
    build_plan_sha256: value.build_plan_sha256,
    profile: value.profile.name,
    overlay_sha256: value.profile.overlay_sha256,
    replacements: value.profile.replacements,
    runtime_roots: value.runtime_roots,
    artifacts: [{package_name: item.package_name, package_id: item.package_id, artifact_key: item.artifact_key} for item in value.artifacts],
    generation_sha256: value.generation_sha256,
  }
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

proc container_load_generation_plan(request: ContainerProfileBuildRequest) [fs, error] -> Result[pm_types.GenerationPlan] {
  let value = pm_plan_json.read(container_build_plan_path())?
  let overlay = container_overlay_root(request.name)
  let profile = pm_generation.overlay_profile(overlay)?

  if profile.name != request.name {
    return Err(ContainerBuildError.Failed(f"overlay profile ${profile.name} does not match ${request.name}"))
  }

  pm_generation.plan_profile(value, request.runtime_roots, profile)
}

proc container_write_generation_plan(value: pm_types.GenerationPlan) [fs, error] {
  fs.write_atomic(container_generation_plan_path(), json.encode(container_generation_plan_dto(value))? + "\n")?
}

proc container_publish_generation_receipt(root: Path, expected: pm_types.GenerationReceipt) [fs, error] {
  let actual = pm_generation.read_generation_receipt(root)?

  if actual != expected {
    return Err(ContainerBuildError.Failed("completed generation receipt does not match its plan"))
  }

  fs.write_atomic(container_generation_receipt_path(), fs.read_text(fp"${root}/var/lib/laputa/generation.json")?)?
}

proc container_ensure_generation(value: pm_types.GenerationPlan, request: ContainerProfileBuildRequest) [fs, error] -> Result[pm_types.GenerationReceipt] {
  let root = container_generation_root(value.generation_sha256)

  if fs.exists(root)? {
    let receipt = pm_generation.read_generation_receipt(root)?
    if receipt.generation_sha256 != value.generation_sha256 or receipt.build_plan_sha256 != value.build_plan_sha256 {
      return Err(ContainerBuildError.Failed(f"existing generation ${value.generation_sha256} does not match the saved plan"))
    }
    pm_generation.verify_generation(root, receipt)?
    container_publish_generation_receipt(root, receipt)?
    return receipt
  }

  let receipt = pm_generation.compose(value, container_store_root(), root, container_overlay_root(request.name))?
  pm_generation.verify_generation(root, receipt)?
  container_publish_generation_receipt(root, receipt)?
  receipt
}

proc container_require_no_forbidden_packages(receipt: pm_types.GenerationReceipt, request: ContainerProfileBuildRequest) [error] {
  for artifact in receipt.artifacts {
    if artifact.package_name in request.forbidden_packages {
      return Err(ContainerBuildError.Failed(f"generation includes forbidden package ${artifact.package_name}"))
    }
  }
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

proc container_find_kernel_node(value: pm_types.BuildPlan, request: ContainerProfileBuildRequest) [error] -> Result[pm_types.PlanNode] {
  for node in value.nodes {
    if node.name == request.kernel_package {
      return node
    }
  }

  Err(ContainerBuildError.Failed(f"kernel package ${request.kernel_package} is not in the saved BuildPlan"))
}

proc container_kernel_manifest_file(metadata: ContainerArtifactMetadataDto, request: ContainerProfileBuildRequest) [error] -> Result[ContainerArtifactMetadataFileDto] {
  if metadata.name != request.kernel_package {
    return Err(ContainerBuildError.Failed(f"kernel artifact metadata names ${metadata.name}, expected ${request.kernel_package}"))
  }

  for entry in metadata.files {
    if entry.path == request.kernel_path and (entry.kind == "file" or entry.kind == "binary") and entry.sha256 != "" {
      return entry
    }
  }

  Err(ContainerBuildError.Failed(f"kernel artifact metadata does not declare ${request.kernel_path}"))
}

proc container_extract_kernel(value: pm_types.BuildPlan, request: ContainerProfileBuildRequest) [fs, error] {
  let node = container_find_kernel_node(value, request)?
  let receipt = pm_store.lookup(container_store_root(), node.artifact_key)?

  if receipt.package_name != request.kernel_package or receipt.package_id != node.package_id or receipt.key != node.artifact_key {
    return Err(ContainerBuildError.Failed("kernel artifact receipt does not match the BuildPlan"))
  }

  let metadata = json.read(fp"${receipt.artifact_dir}/metadata.json")?.require(ContainerArtifactMetadataDto)?
  let manifest = container_kernel_manifest_file(metadata, request)?
  let handle = fs.tempdir()?
  defer fs.close_root(handle)?
  let extracted = fs.root_path(handle)?
  archive.tar_extract(fp"${receipt.artifact_dir}/payload.tar.gz", extracted, 0, "auto", true)?
  let source = image.image_kernel_source(extracted, fp"${request.kernel_path}")?

  if hash.sha256(source)?.hex() != manifest.sha256 {
    return Err(ContainerBuildError.Failed(f"kernel payload digest does not match metadata for ${request.kernel_path}"))
  }

  image.image_copy_kernel(source, container_kernel_output())?
}

proc container_build_images(root: Path) [fs, process, error] {
  image.image_write_rootfs(root, p"/src/packages/repo/laputa-fs/files/mkfs.ext4.xsh", container_rootfs_output())?
  image.write_disk(container_rootfs_output(), container_disk_output())?
  image.verify_disk(container_disk_output(), fs.metadata(container_rootfs_output())?.size)?
}

proc container_execute_profile(request: ContainerProfileBuildRequest, jobs: Int) [fs, net, process, env, time, error] {
  let plan_value = pm_plan_json.read(container_build_plan_path())?
  let urls = pm_remote.load_repo_urls()?
  let remote_repo = if urls.repo != "" { urls.repo } else { urls.public_repo }
  let _ = pm_execute.build_plan(plan_value, container_package_root(), container_store_root(), remote_repo, jobs)?
  let generation = container_load_generation_plan(request)?
  container_write_generation_plan(generation)?
  let receipt = container_ensure_generation(generation, request)?
  let root = container_generation_root(receipt.generation_sha256)
  container_require_no_forbidden_packages(receipt, request)?
  container_require_no_forbidden_sonames(root, request)?
  container_extract_kernel(plan_value, request)?
  container_build_images(root)?
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
    container_write_generation_plan(container_load_generation_plan(request)?)?
    return
  }

  container_execute_profile(request, jobs)?
}

main(@args)?
