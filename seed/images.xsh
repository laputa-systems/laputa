##! Laputa's two Docker images: the networked host-tools base and the offline package-tools image built on it.
# Layering keeps the networked, drifting part small and rarely rebuilt:
#
# - `laputa-host-tools` is the digest-pinned Alpine base plus its apk
#   toolchain. Building it is the one networked image step and belongs to
#   `make fetch`, which also saves it to `.cache/images/` so later runs
#   `docker load` it offline. apk is unpinned, so the saved tar, not a
#   rebuild, is what keeps it stable.
# - `laputa-package-tools` adds the prebuilt LLVM seed from the source cache,
#   built with `--network none`.
#
# Neither image contains XSH, PM, or recipes. Containers mount the seed XSH
# and the checkout at run time, so an XSH or PM change rebuilds no image.
# Tags are content keys over each image's own inputs.
use pm.recipe as pm_recipe
use pm.sources as pm_sources
use pm.types as pm_types
use seed.xsh_seed

## Errors raised when an image input is missing or a Docker step fails.
export error SeedImageError = Missing : NotFound | Failed : ProcessFailure

const host_tools_contract_epoch = "laputa-host-tools-1"
const package_tools_contract_epoch = "laputa-package-tools-2"

## The Docker client: `DOCKER` when set, else `docker` on PATH.
export proc docker_program() [process, env, error] -> Result[Path, Error] {
  let configured = (e"DOCKER" ?? "").trim()
  return fp"{configured}" unless configured == ""

  process.which("docker")?
}

## The checked-in Dockerfile for the networked host-tools base.
export pure host_tools_dockerfile(laputa_root: Path) -> Path {
  fp"{laputa_root}/seed/Dockerfile.host-tools"
}

## The checked-in Dockerfile for the offline package-tools image.
export pure package_tools_dockerfile(laputa_root: Path) -> Path {
  fp"{laputa_root}/Dockerfile.package-tools"
}

pure package_tools_bootstrap_helper(laputa_root: Path) -> Path {
  fp"{laputa_root}/bootstrap-llvm-seed.xsh"
}

pure llvm_recipe_dir(laputa_root: Path) -> Path {
  fp"{laputa_root}/packages/llvm-toolchain"
}

pure short_key(key: Str) -> Str {
  key.byte_slice(0, length: 16)
}

proc require_file(file: Path) {
  if ! file.exists() or ! file.is_file() {
    return Err(SeedImageError.Missing(f"image input is missing: {file}"))
  }
}

proc tree_digest(root: Path) -> Result[Str] {
  guard root.exists() else {
    return Err(SeedImageError.Missing(f"image input is missing: {root}"))
  }

  let lines = [
    f"{entry.path.strip_prefix(root)?.display()}\t{hash.sha256(entry.path)?.hex()}"
    for entry in fs.files(root)
  ]
  let sorted = lines |> sort
  bytes.from_text(sorted.join("\n") + "\n").sha256().hex()
}

## The content key for the host-tools base: its Dockerfile and platform.
export proc host_tools_key(laputa_root: Path, value: xsh_seed.SeedArch) [fs, error] -> Result[Str, Error] {
  let dockerfile = host_tools_dockerfile(laputa_root)
  require_file(dockerfile)
  let body = f"""{host_tools_contract_epoch}
dockerfile\t{hash.sha256(dockerfile)?.hex()}
platform\t{value.docker_platform}
"""
  bytes.from_text(body).sha256().hex()
}

## The host-tools tag for one architecture.
export proc host_tools_tag(laputa_root: Path, value: xsh_seed.SeedArch) [fs, error] -> Result[Str, Error] {
  f"laputa-host-tools:{value.arch}-{short_key(host_tools_key(laputa_root, value)?)}"
}

## Where `make fetch` saves the host-tools base so later runs load it offline.
export proc host_tools_saved_image(laputa_root: Path, value: xsh_seed.SeedArch) [fs, error] -> Result[Path, Error] {
  let name = host_tools_tag(laputa_root, value)?.replace(":", with: "-")
  fp"{laputa_root}/.cache/images/{name}.tar"
}

## The pinned LLVM seed archive digest for one architecture, read through the typed recipe boundary.
export proc llvm_seed_sha256(laputa_root: Path, arch: Str) [fs, env, error] -> Result[Str, Error] {
  let pkg = pm_recipe.load_package_for_target(llvm_recipe_dir(laputa_root), pm_types.parse_target(arch)?)?

  if pkg.upstream_sources.len() != 1 {
    return Err(SeedImageError.Missing("packages/llvm-toolchain must declare exactly one LLVM seed source"))
  }

  pm_sources.source_checksum(pkg.upstream_sources[0], arch)?
}

## The fetched LLVM seed archive in the content-addressed source cache.
export proc llvm_seed_source(laputa_root: Path, arch: Str) [fs, env, error] -> Result[Path, Error] {
  fp"{laputa_root}/.cache/sources/sha256/{llvm_seed_sha256(laputa_root, arch)?}"
}

## The content key for package-tools: its Dockerfile, the LLVM bootstrap helper and recipe, and the base tag.
## XSH and PM only run the bootstrap helper; like artifact keys, the key records neither.
export proc package_tools_key(laputa_root: Path, value: xsh_seed.SeedArch) [fs, error] -> Result[Str, Error] {
  let dockerfile = package_tools_dockerfile(laputa_root)
  let helper = package_tools_bootstrap_helper(laputa_root)
  require_file(dockerfile)
  require_file(helper)
  let body = f"""{package_tools_contract_epoch}
dockerfile\t{hash.sha256(dockerfile)?.hex()}
bootstrap-helper\t{hash.sha256(helper)?.hex()}
llvm-seed-recipe\t{tree_digest(llvm_recipe_dir(laputa_root))?}
host-tools\t{host_tools_tag(laputa_root, value)?}
platform\t{value.docker_platform}
"""
  bytes.from_text(body).sha256().hex()
}

## The package-tools tag for one architecture.
export proc package_tools_tag(laputa_root: Path, value: xsh_seed.SeedArch) [fs, error] -> Result[Str, Error] {
  f"laputa-package-tools:{value.arch}-{short_key(package_tools_key(laputa_root, value)?)}"
}

proc quiet_status(docker: Path, argv: List[Str], cwd: Path) -> Result[Bool] {
  let handle = fs.tempdir()?
  defer handle.close()
  let quiet = fp"{handle.host_path()?}/output"
  let status = process.run(process.command_argv(docker, argv, cwd, stdout: quiet, stderr: quiet))?
  status.ok
}

## Report whether a local image tag exists.
export proc image_exists(docker: Path, tag: Str, cwd: Path) [fs, process, error] -> Result[Bool, Error] {
  quiet_status(docker, [docker.display(), "image", "inspect", tag], cwd)?
}

proc docker_step(docker: Path, argv: List[Str], cwd: Path, what: Str) {
  let status = process.run(process.command_argv(docker, argv, cwd))?

  return Err(SeedImageError.Failed(f"{what} failed")) unless status.ok
}

## Construct the networked host-tools build.
export proc host_tools_build_argv(
  docker: Path,
  laputa_root: Path,
  value: xsh_seed.SeedArch,
) [fs, error] -> Result[List[Str], Error] {
  [
    docker.display(),
    "build",
    "--platform",
    value.docker_platform,
    "--file",
    host_tools_dockerfile(laputa_root).display(),
    "--tag",
    host_tools_tag(laputa_root, value)?,
    fp"{laputa_root}/seed".display(),
  ]
}

## Build the host-tools base if needed and save it under `.cache/images/`. This is the networked image step.
export proc fetch_host_tools(docker: Path, laputa_root: Path, value: xsh_seed.SeedArch) [fs, process, error] {
  let tag = host_tools_tag(laputa_root, value)?
  let saved = host_tools_saved_image(laputa_root, value)?

  return when saved.exists()

  if ! image_exists(docker, tag, laputa_root) {
    docker_step(docker, host_tools_build_argv(docker, laputa_root, value)?, laputa_root, f"building {tag}")
  }

  saved.parent.mkdir()
  atomically replace saved as temporary {
    docker_step(docker, [docker.display(), "save", "--output", temporary.display(), tag], laputa_root, f"saving {tag}")
  }
}

## Make the host-tools base available offline: present, or loaded from `.cache/images/`.
export proc ensure_host_tools(
  docker: Path,
  laputa_root: Path,
  value: xsh_seed.SeedArch,
) [fs, process, error] -> Result[Str, Error] {
  let tag = host_tools_tag(laputa_root, value)?

  return tag when image_exists(docker, tag, laputa_root)

  let saved = host_tools_saved_image(laputa_root, value)?
  if ! saved.exists() {
    return Err(SeedImageError.Missing(f"{tag} is neither loaded nor saved at {saved}; run `make fetch`"))
  }

  docker_step(docker, [docker.display(), "load", "--input", saved.display()], laputa_root, f"loading {saved}")

  if ! image_exists(docker, tag, laputa_root) {
    return Err(SeedImageError.Failed(f"{saved} did not provide {tag}"))
  }

  tag
}

# BuildKit transfers a whole named context, so the LLVM archive is staged
# alone instead of naming the full source cache. The cache file is copied, not
# moved: `.cache/` stays the only owner of fetched inputs.
proc stage_llvm_source(laputa_root: Path, arch: Str) -> Result[Path] {
  let source = llvm_seed_source(laputa_root, arch)?
  let digest = llvm_seed_sha256(laputa_root, arch)?

  if ! source.exists() {
    return Err(SeedImageError.Missing(f"the {arch} LLVM seed {source} is not fetched; run `make fetch`"))
  }

  let context = fp"{laputa_root}/.out/package-tools/{arch}/sources"
  let staged = fp"{context}/sha256/{digest}"

  if ! staged.exists() {
    context.remove()
    staged.parent.mkdir()
    source.copy(to: staged)
  }

  context
}

## Construct the offline package-tools build.
export pure package_tools_build_argv(
  docker: Path,
  laputa_root: Path,
  value: xsh_seed.SeedArch,
  host_tag: Str,
  tag: Str,
  sources: Path,
) -> List[Str] {
  [
    docker.display(),
    "build",
    "--platform",
    value.docker_platform,
    "--network",
    "none",
    "--file",
    package_tools_dockerfile(laputa_root).display(),
    "--target",
    "package-tools",
    "--build-arg",
    f"HOST_TOOLS_IMAGE={host_tag}",
    "--build-arg",
    f"XSH_PM_TARGET_ARCH={value.arch}",
    "--build-context",
    f"seed={xsh_seed.xsh_seed_dir(laputa_root, value.arch)}",
    "--build-context",
    f"sources={sources}",
    "--tag",
    tag,
    laputa_root.display(),
  ]
}

## Ensure the package-tools image for one architecture exists, building it offline when its key is new.
export proc ensure_package_tools(
  docker: Path,
  laputa_root: Path,
  value: xsh_seed.SeedArch,
) [fs, process, env, error] -> Result[Str, Error] {
  let tag = package_tools_tag(laputa_root, value)?

  return tag when image_exists(docker, tag, laputa_root)

  let host_tag = ensure_host_tools(docker, laputa_root, value)?
  let _ = xsh_seed.xsh_seed_require(laputa_root, value.arch)?
  let sources = stage_llvm_source(laputa_root, value.arch)?
  docker_step(
    docker,
    package_tools_build_argv(docker, laputa_root, value, host_tag, tag, sources),
    laputa_root,
    f"building {tag}",
  )
  tag
}
