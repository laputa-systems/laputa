##! Laputa's two Docker images: the networked host-tools base and the offline package-tools image built on it.
use pm.recipe as pm_recipe
use pm.sources as pm_sources
use pm.types as pm_types
use seed.xsh_seed

## Errors raised when an image input is missing or a Docker step fails.
export error SeedImageError = Missing : NotFound | Failed : ProcessFailure

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

## The published host-tools digest, checked against its build input.
export proc host_tools_tag(laputa_root: Path, value: xsh_seed.SeedArch) [fs, error] -> Result[Str, Error] {
  let lock = json.read(fp"{laputa_root}/seed/images.lock")?.require(Record)?
  let expected = lock.get("dockerfile_sha256")?.require(Str)?
  let dockerfile = host_tools_dockerfile(laputa_root)
  require_file(dockerfile)
  if hash.sha256(dockerfile)?.hex() != expected {
    return Err(SeedImageError.Missing("stale image lock; rebuild and repin with `xsh seed/images.xsh -- build --arch ARCH --seed-root PATH --sources PATH`"))
  }
  let digest = lock.get(value.arch)?.require(Str)?
  if ! digest.starts_with("sha256:") or digest.byte_len() != 71 {
    return Err(SeedImageError.Missing("invalid host-tools digest in seed/images.lock"))
  }
  f"oci.17166969.xyz/laputa-host-tools@{digest}"
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

## The content key for package-tools: its Dockerfile, the LLVM bootstrap helper and recipe, and the base digest.
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

## The package-tools publication is valid only for its recorded input key.
export proc package_tools_image(laputa_root: Path, value: xsh_seed.SeedArch) [fs, error] -> Result[Str, Error] {
  let key = package_tools_key(laputa_root, value)?
  let lock = json.read(fp"{laputa_root}/seed/images.lock")?.require(Record)?
  let recorded = lock.get(f"package_key_{value.arch}")?.require(Str)?
  if key != recorded {
    return Err(SeedImageError.Missing("stale image lock; rebuild and repin with `xsh seed/images.xsh -- build --arch ARCH --seed-root PATH --sources PATH`"))
  }
  let digest = lock.get(f"package_digest_{value.arch}")?.require(Str)?
  if ! digest.starts_with("sha256:") or digest.byte_len() != 71 {
    return Err(SeedImageError.Missing("invalid package-tools digest in seed/images.lock"))
  }
  f"oci.17166969.xyz/laputa-package-tools@{digest}"
}

proc quiet_status(docker: Path, argv: List[Str], cwd: Path) -> Result[Bool] {
  let handle = fs.tempdir()?
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

## Fetch the published base by digest.
export proc fetch_host_tools(docker: Path, laputa_root: Path, value: xsh_seed.SeedArch) [fs, process, error] {
  let image = host_tools_tag(laputa_root, value)?
  let tools = package_tools_image(laputa_root, value)?
  docker_step(docker, [docker.display(), "pull", "--platform", value.docker_platform, image], laputa_root, f"pulling {image}")
  docker_step(docker, [docker.display(), "pull", "--platform", value.docker_platform, tools], laputa_root, f"pulling {tools}")
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

## Require the explicitly built package-tools image.
export proc ensure_package_tools(
  docker: Path,
  laputa_root: Path,
  value: xsh_seed.SeedArch,
) [fs, process, env, error] -> Result[Str, Error] {
  let tag = package_tools_image(laputa_root, value)?
  if ! image_exists(docker, tag, laputa_root) {
    return Err(SeedImageError.Missing(f"{tag} is missing; rebuild and repin with `xsh seed/images.xsh -- build --arch ARCH --seed-root PATH --sources PATH`"))
  }
  tag
}

proc main(...argv: List[Str]) [fs, process, env, error] {
  if argv.len() == 3 and argv[1] == "--arch" {
    let value = xsh_seed.xsh_seed_arch(argv[2])?
    if argv[0] == "key" {
      print package_tools_key(fs.cwd()?, value)?
      return
    }
    if argv[0] == "ref" {
      print package_tools_image(fs.cwd()?, value)?
      return
    }
  }
  if argv.len() != 7 or argv[0] != "build" or argv[1] != "--arch" or argv[3] != "--seed-root" or argv[5] != "--sources" {
    return Err(SeedImageError.Missing("usage: xsh seed/images.xsh -- build --arch ARCH --seed-root PATH --sources PATH"))
  }
  let root = fs.cwd()?
  let value = xsh_seed.xsh_seed_arch(argv[2])?
  let docker = docker_program()?
  let builds = fp"{root}/.work/images/{value.arch}"
  builds.mkdir()
  let output = fp"{builds}/.staging"
  output.remove()
  output.mkdir()
  let host = "laputa-host-tools:local-build"
  let host_tar = fp"{output}/host-tools.tar"
  docker_step(docker, [docker.display(), "buildx", "build", "--platform", value.docker_platform, "--file", host_tools_dockerfile(root).display(), "--tag", host, "--output", f"type=oci,dest={host_tar}", "--load", fp"{root}/seed".display()], root, "building host-tools layout")
  let host_layout = fp"{output}/host-tools"
  host_layout.mkdir()
  docker_step(p"tar", ["tar", "-xf", host_tar.display(), "-C", host_layout.display()], root, "extracting host-tools layout")
  let tools_tar = fp"{output}/package-tools.tar"
  docker_step(docker, [docker.display(), "buildx", "build", "--platform", value.docker_platform, "--network", "none", "--file", package_tools_dockerfile(root).display(), "--target", "package-tools", "--build-arg", f"HOST_TOOLS_IMAGE={host}", "--build-arg", f"XSH_PM_TARGET_ARCH={value.arch}", "--build-context", f"seed={argv[4]}", "--build-context", f"sources={argv[6]}", "--output", f"type=oci,dest={tools_tar}", root.display()], root, "building package-tools layout")
  let tools_layout = fp"{output}/package-tools"
  tools_layout.mkdir()
  docker_step(p"tar", ["tar", "-xf", tools_tar.display(), "-C", tools_layout.display()], root, "extracting package-tools layout")
  let key = hash.sha256(fp"{tools_layout}/index.json")?.hex()
  let complete = fp"{builds}/{key}"
  if complete.exists() {
    output.remove()
  } else {
    output.rename(to: complete)
  }
  atomically replace fp"{builds}/current" as temporary {
    temporary.symlink(to: fp"{key}")
  }
  print f"layouts: {complete}/host-tools {complete}/package-tools"
}
