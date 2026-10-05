##! The local XSH seed: static musl `xsh`, `xshi`, `xsht` and the core applet tarball built from the XSH_ROOT checkout.
# The seed is never a published release. It is built from whatever XSH_ROOT
# holds, inside XSH's own `Dockerfile.test` image (`xsh-test`) with the musl
# link flags XSH's Linux test path uses, so a Linux build here is the same
# evidence `cargo dev test linux` produces. The build runs with
# `--network none`: the crate registry comes from `.cache/cargo`, filled by
# `seed fetch`.

## One supported seed architecture and the names each tool uses for it.
export type SeedArch = {arch: Str, triple: Str, docker_platform: Str}

## One environment variable passed to the seed build container.
export type SeedEnvVar = {name: Str, value: Str}

## Errors raised when the seed inputs, build, or outputs violate their contract.
export error SeedError = Usage(message: Str) : Usage | Missing(message: Str) : NotFound | Failed(message: Str) : ProcessFailure

## The XSH image whose toolchain and musl CRT objects every Linux XSH build links against.
export const xsh_seed_build_image = "xsh-test"

const xsh_seed_manifest_format = "laputa-xsh-seed-1"

# XSH's distribution feature set: release binaries carry the network and tool
# modules and xsht's native test runner, but not the xsh crate's own tests.
const xsh_seed_features = "xsh/net xsh/tools xsht/native-tests"

## The products a seed directory holds beside its manifest; `core` is the tarball's extracted tree.
export const xsh_seed_binaries = ["xsh", "xshi", "xsht"]

## Resolve a seed architecture name.
export pure xsh_seed_arch(arch: Str) -> Result[SeedArch, Error] {
  match arch {
    "aarch64" => {arch: "aarch64", triple: "aarch64-unknown-linux-musl", docker_platform: "linux/arm64"}
    "x86_64" => {arch: "x86_64", triple: "x86_64-unknown-linux-musl", docker_platform: "linux/amd64"}
    _ => Err(SeedError.Usage(f"unsupported seed architecture {arch}; expected aarch64 or x86_64"))
  }
}

## The derived seed output directory for one architecture.
export pure xsh_seed_dir(laputa_root: Path, arch: Str) -> Path {
  fp"{laputa_root}/.out/seed/{arch}"
}

## The seed manifest recording product digests and the XSH revision that built them.
export pure xsh_seed_manifest_path(laputa_root: Path, arch: Str) -> Path {
  fp"{xsh_seed_dir(laputa_root, arch)}/manifest.json"
}

# Cargo separates outputs by target triple, so one target directory serves
# every seed architecture and survives between seeds for incremental builds.
pure xsh_seed_cargo_target(laputa_root: Path) -> Path {
  fp"{laputa_root}/.out/xsh-target"
}

pure xsh_seed_cargo_registry(laputa_root: Path) -> Path {
  fp"{laputa_root}/.cache/cargo/registry"
}

# Records which Cargo.lock the cached registry was fetched for, so a seed
# build fails with a clear instruction instead of a cargo offline error.
pure xsh_seed_registry_stamp(laputa_root: Path) -> Path {
  fp"{laputa_root}/.cache/cargo/Cargo.lock.sha256"
}

## The Rust flags XSH's Linux test path sets for a static musl target.
## These mirror XSH's `dev/targets.xsh::docker_test_env`; the `__isoc23_*`
## aliases match the CRT objects in the `xsh-test` image.
export pure xsh_seed_rustflags_env(value: SeedArch) -> Result[SeedEnvVar, Error] {
  let flags = [
    "-C target-feature=+crt-static",
    "-C link-arg=--defsym=__isoc23_sscanf=sscanf",
    "-C link-arg=--defsym=__isoc23_strtol=strtol",
  ].join(" ")

  match value.triple {
    "x86_64-unknown-linux-musl" => {name: "CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS", value: flags}
    "aarch64-unknown-linux-musl" => {name: "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS", value: flags}
    _ => Err(SeedError.Usage(f"no musl link flags for {value.triple}"))
  }
}

## Construct the offline release build of the three XSH products inside `xsh-test`.
export pure xsh_seed_cargo_build_argv(
  docker: Path,
  laputa_root: Path,
  xsh_root: Path,
  value: SeedArch,
  jobs: Int,
) -> Result[List[Str], Error] {
  let rustflags = xsh_seed_rustflags_env(value)?
  [
    docker.display(),
    "run",
    "--rm",
    "--platform",
    value.docker_platform,
    "--network",
    "none",
    "--mount",
    f"type=bind,src={xsh_root},dst=/work,readonly",
    "--mount",
    f"type=bind,src={xsh_seed_cargo_target(laputa_root)},dst=/target",
    "--mount",
    f"type=bind,src={xsh_seed_cargo_registry(laputa_root)},dst=/root/.cargo/registry",
    "--workdir",
    "/work",
    "--env",
    "CARGO_TARGET_DIR=/target",
    "--env",
    "CARGO_NET_OFFLINE=true",
    # The release profile's thin LTO and non-incremental codegen made a
    # one-line XSH edit cost a full ~7 minute rebuild at -j 4; without LTO and
    # with incremental codegen the same edit rebuilds in ~13 s. The binaries
    # stay opt-level 3 and grow by about 1%. The dist profile is reserved for
    # XSH's release packaging.
    "--env",
    "CARGO_PROFILE_RELEASE_LTO=false",
    "--env",
    "CARGO_PROFILE_RELEASE_INCREMENTAL=true",
    "--env",
    f"{rustflags.name}={rustflags.value}",
    xsh_seed_build_image,
    "cargo",
    "build",
    "--locked",
    "--offline",
    "--release",
    "-j",
    f"{jobs}",
    "--target",
    value.triple,
    "-p",
    "xsh",
    "-p",
    "xshi",
    "-p",
    "xsht",
    "--no-default-features",
    "--features",
    xsh_seed_features,
    "--bin",
    "xsh",
    "--bin",
    "xshi",
    "--bin",
    "xsht",
  ]
}

## Construct the networked crate fetch that fills `.cache/cargo/registry` for every target.
export pure xsh_seed_cargo_fetch_argv(docker: Path, laputa_root: Path, xsh_root: Path, value: SeedArch) -> List[Str] {
  [
    docker.display(),
    "run",
    "--rm",
    "--platform",
    value.docker_platform,
    "--mount",
    f"type=bind,src={xsh_root},dst=/work,readonly",
    "--mount",
    f"type=bind,src={xsh_seed_cargo_registry(laputa_root)},dst=/root/.cargo/registry",
    "--workdir",
    "/work",
    xsh_seed_build_image,
    "cargo",
    "fetch",
    "--locked",
  ]
}

proc xsh_seed_run(docker: Path, argv: List[Str], cwd: Path, what: Str) [process, error] {
  let status = process.run(process.command_argv(docker, argv, cwd))?

  return Err(SeedError.Failed(f"{what} failed")) unless status.ok
}

proc xsh_seed_image_exists(docker: Path, image: Str, cwd: Path) [fs, process, error] -> Result[Bool] {
  let handle = fs.tempdir()?
  defer handle.close()?
  let quiet = fp"{handle.host_path()?}/inspect"
  let status = process.run(
    process.command_argv(docker, [docker.display(), "image", "inspect", image], cwd, stdout: quiet, stderr: quiet),
  )?
  status.ok
}

proc xsh_seed_require_checkout(xsh_root: Path) [fs, error] {
  for required in [fp"{xsh_root}/Cargo.lock", fp"{xsh_root}/Dockerfile.test", fp"{xsh_root}/core"] {
    guard fs.exists(required)? else {
      return Err(SeedError.Missing(f"XSH_ROOT is not an XSH checkout: {required} is missing"))
    }
  }
}

## Fetch the seed's networked inputs: the `xsh-test` image and the crate registry for XSH_ROOT's Cargo.lock.
export proc xsh_seed_fetch(docker: Path, laputa_root: Path, xsh_root: Path, value: SeedArch) [fs, process, error] {
  xsh_seed_require_checkout(xsh_root)?

  if ! xsh_seed_image_exists(docker, xsh_seed_build_image, laputa_root)? {
    xsh_seed_run(
      docker,
      [
        docker.display(),
        "build",
        "--platform",
        value.docker_platform,
        "--tag",
        xsh_seed_build_image,
        "--file",
        fp"{xsh_root}/Dockerfile.test".display(),
        xsh_root.display(),
      ],
      laputa_root,
      f"building {xsh_seed_build_image} from {xsh_root}/Dockerfile.test",
    )?
  }

  fs.mkdir(xsh_seed_cargo_registry(laputa_root))?
  xsh_seed_run(
    docker,
    xsh_seed_cargo_fetch_argv(docker, laputa_root, xsh_root, value),
    laputa_root,
    "fetching XSH crates",
  )?
  fs.write_atomic(xsh_seed_registry_stamp(laputa_root), hash.sha256(fp"{xsh_root}/Cargo.lock")?.hex())?
}

proc xsh_seed_require_fetched(docker: Path, laputa_root: Path, xsh_root: Path) [fs, process, error] {
  guard xsh_seed_image_exists(docker, xsh_seed_build_image, laputa_root)? else {
    return Err(SeedError.Missing(f"Docker image {xsh_seed_build_image} is missing; run `make fetch`"))
  }

  let stamp = xsh_seed_registry_stamp(laputa_root)
  let lock = hash.sha256(fp"{xsh_root}/Cargo.lock")?.hex()

  if ! fs.exists(stamp)? or fs.read_text(stamp)?.trim() != lock {
    return Err(SeedError.Missing(f"the cached crate registry does not match {xsh_root}/Cargo.lock; run `make fetch`"))
  }
}

## XSH release packaging installs commands without `.xsh` and keeps library
## modules as `lib/*.xsh` so `use lib.*` resolves beside the commands. This
## mirrors XSH's `dev/release.xsh::core_install_path`.
export pure xsh_seed_core_install_path(relative_source: Path) -> Path {
  return fp"core/{relative_source}" when relative_source.display().starts_with("lib/")

  let relative = relative_source.display()
  let command = if relative.ends_with(".xsh") {
    relative.byte_slice(0, length: relative.byte_len() - 4)
  } else {
    relative
  }
  fp"core/{command}"
}

proc xsh_seed_core_sources(xsh_root: Path) [fs, error] -> Result[List[Path]] {
  let core = fp"{xsh_root}/core"
  var sources = []

  for entry in fs.walk(core, hidden: true)? {
    if entry.kind == "file" and entry.path.ext() == "xsh" {
      let relative = entry.path.relative_to(core)

      if ! relative.display().starts_with("tests/") {
        sources += [relative]
      }
    }
  }

  sources |> sort
}

# Tar members carry staging mtimes, so the tarball is rebuilt only when this
# digest of the packaged sources changes; otherwise its sha256 stays stable and
# the `xsh` package keeps its build key.
proc xsh_seed_core_digest(xsh_root: Path, sources: List[Path]) [fs, error] -> Result[Str] {
  let lines = [f"{relative}\t{hash.sha256(fp"{xsh_root}/core/{relative}")?.hex()}" for relative in sources]
  bytes.from_text(lines.join("\n") + "\n").sha256().hex()
}

proc xsh_seed_write_core(xsh_root: Path, sources: List[Path], archive_path: Path) [fs, error] {
  let handle = fs.tempdir()?
  defer handle.close()?
  let stage = handle.host_path()?
  var entries = []

  for relative in sources {
    let installed = xsh_seed_core_install_path(relative)
    let mode = if relative.display().starts_with("lib/") { 0o644 } else { 0o755 }
    fs.install(fp"{xsh_root}/core/{relative}", fp"{stage}/{installed}", mode, parents: true, overwrite: true)?
    entries += [installed]
  }

  let temporary = fp"{archive_path}.tmp"
  fs.remove(temporary, missing_ok: true)?
  archive.tar_create(temporary, stage, entries, "xz", true)?
  fs.rename(temporary, archive_path, overwrite: true)?
}

# Replace a product only when its bytes changed, so an unchanged rebuild keeps
# the seed directory, and with it the `xsh` package key, byte-identical.
proc xsh_seed_publish_binary(source: Path, dest: Path) [fs, error] {
  guard fs.exists(source)? else {
    return Err(SeedError.Missing(f"cargo did not produce {source}"))
  }

  return when fs.exists(dest)? and hash.sha256(dest)?.hex() == hash.sha256(source)?.hex()

  let temporary = fp"{dest}.tmp"
  fs.install(source, temporary, 0o755, parents: true, overwrite: true)?
  fs.rename(temporary, dest, overwrite: true)?
}

proc xsh_seed_git_text(xsh_root: Path, argv: List[Str]) [process, error] -> Result[Str] {
  let output = run.text git -C $xsh_root @argv ?
  output.trim()
}

proc xsh_seed_previous_core_digest(manifest: Path) [fs, error] -> Result[Str] {
  return "" unless fs.exists(manifest)?

  let value = json.read(manifest)?.require(Record)?
  let digest: Str = value.get("core_sources_sha256")?.require()?
  digest
}

## Build the seed for one architecture from XSH_ROOT and record its manifest.
export proc xsh_seed_build(
  docker: Path,
  laputa_root: Path,
  xsh_root: Path,
  value: SeedArch,
  jobs: Int,
) [fs, process, error] {
  guard jobs >= 1 else {
    return Err(SeedError.Usage("seed build jobs must be positive"))
  }

  xsh_seed_require_checkout(xsh_root)?
  xsh_seed_require_fetched(docker, laputa_root, xsh_root)?
  fs.mkdir(xsh_seed_cargo_target(laputa_root))?
  xsh_seed_run(
    docker,
    xsh_seed_cargo_build_argv(docker, laputa_root, xsh_root, value, jobs)?,
    laputa_root,
    f"building the {value.arch} XSH seed",
  )?

  let out = xsh_seed_dir(laputa_root, value.arch)
  let manifest = xsh_seed_manifest_path(laputa_root, value.arch)
  fs.mkdir(out)?

  for product in xsh_seed_binaries {
    xsh_seed_publish_binary(
      fp"{xsh_seed_cargo_target(laputa_root)}/{value.triple}/release/{product}",
      fp"{out}/{product}",
    )?
  }

  let core_archive = fp"{out}/core.tar.xz"
  let sources = xsh_seed_core_sources(xsh_root)?
  let core_digest = xsh_seed_core_digest(xsh_root, sources)?

  let core_tree = fp"{out}/core"

  if ! fs.exists(core_archive)? or xsh_seed_previous_core_digest(manifest)? != core_digest {
    xsh_seed_write_core(xsh_root, sources, core_archive)?
    fs.remove(core_tree, missing_ok: true)?
  }

  # The extracted tree is what containers mount at /usr/lib/xsh/core, so the
  # mounted applets are exactly the packaged ones.
  if ! fs.exists(core_tree)? {
    archive.tar_extract(core_archive, out, 0, "xz", true)?
  }

  var files: Map[Str] = {product: hash.sha256(fp"{out}/{product}")?.hex() for product in xsh_seed_binaries}
  files["core.tar.xz"] = hash.sha256(core_archive)?.hex()

  let dirty = xsh_seed_git_text(xsh_root, ["status", "--porcelain"])? != ""
  let record = {
    format: xsh_seed_manifest_format,
    arch: value.arch,
    triple: value.triple,
    cargo_profile: "release, lto=false, incremental",
    features: xsh_seed_features,
    xsh_commit: xsh_seed_git_text(xsh_root, ["rev-parse", "HEAD"])?,
    xsh_dirty: dirty,
    core_sources_sha256: core_digest,
    files,
  }
  let text = json.encode(record, pretty: true)? + "\n"

  if ! fs.exists(manifest)? or fs.read_text(manifest)? != text {
    fs.write_atomic(manifest, text)?
  }
}

## Verify a built seed: every product exists and matches the digest its manifest records.
export proc xsh_seed_require(laputa_root: Path, arch: Str) [fs, error] -> Result[Path, Error] {
  let out = xsh_seed_dir(laputa_root, arch)
  let manifest = xsh_seed_manifest_path(laputa_root, arch)

  if ! fs.exists(manifest)? {
    return Err(SeedError.Missing(f"the {arch} XSH seed is missing at {out}; run `make seed`"))
  }

  let value = json.read(manifest)?.require(Record)?
  let format: Str = value.get("format")?.require()?
  if format != xsh_seed_manifest_format {
    return Err(SeedError.Failed(f"{manifest} has format {format}; run `make seed`"))
  }

  let files = value.get("files")?.require(Record)?
  for name in xsh_seed_binaries.push("core.tar.xz") {
    let expected: Str = files.get(name)?.require()?
    let file = fp"{out}/{name}"

    if ! fs.exists(file)? or hash.sha256(file)?.hex() != expected {
      return Err(SeedError.Failed(f"{file} does not match {manifest}; run `make seed`"))
    }
  }

  if ! fs.exists(fp"{out}/core")? {
    return Err(SeedError.Missing(f"the extracted core tree {out}/core is missing; run `make seed`"))
  }

  out
}

## Construct the read-only Docker mounts that place a verified seed in a container.
## Binaries and core applets come from one seed directory, so a container
## never pairs one XSH build's interpreter with another build's applets.
export pure xsh_seed_mount_argv(seed: Path) -> List[Str] {
  var argv = []

  for product in xsh_seed_binaries {
    argv = argv.extend(["--mount", f"type=bind,src={seed}/{product},dst=/bin/{product},readonly"])
  }

  argv.extend(["--mount", f"type=bind,src={seed}/core,dst=/usr/lib/xsh/core,readonly"])
}
