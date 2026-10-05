##! Typed package-recipe loading and dynamic procedure invocation. This is the sole boundary that reads dynamic `PKGBUILD.xsh` exports; all callers receive `types.Package` records and use its call helpers rather than retaining dynamic module values.
use recipe_hooks as hooks
use types
use util

type PackageMetadata = {
  name: Str,
  ver: Str,
  rel: Str,
  architectures: List[Str],
  deps: List[Str],
  runtime_only_deps: List[Str],
  mkdeps_host: List[Str],
  mkdeps_target: List[Str],
  upstream_sources: List[Record],
  filetree: List[Record],
  filetree_aarch64: List[Record],
  has_filetree_aarch64: Bool,
  filetree_x86_64: List[Record],
  has_filetree_x86_64: Bool,
  has_build: Bool,
  package_kind: Str,
  has_package_kind: Bool,
  nostrip: Bool,
  source_mirror: Bool,
}

proc package_contract_error(pkg: Str, message: Str) [error] {
  return Err(types.PmError.PackageContract(f"{pkg}: {message}"))
}

proc validate_package_name(name: Str) {
  let pattern = rx"^[a-z0-9][a-z0-9+._-]*$"

  if ! pattern.matches(name) {
    return package_contract_error(name, "name must match [a-z0-9][a-z0-9+._-]*")
  }
}

proc validate_positive_release(name: Str, rel: Str) {
  let pattern = rx"^[1-9][0-9]*$"

  if ! pattern.matches(rel) {
    return package_contract_error(name, "rel must be a positive decimal string")
  }
}

# A package architecture list names each supported target at most once and
# never `all`: omitting the export is the one way to say every target.
proc validate_package_architectures(name: Str, architectures: List[Str]) {
  if architectures.len() == 0 {
    return package_contract_error(name, "architectures must name at least one target architecture")
  }

  var seen: Map[Bool] = {}

  for architecture in architectures {
    if architecture != "aarch64" and architecture != "x86_64" {
      return package_contract_error(name, f"architectures has unsupported architecture {architecture}")
    }

    if architecture in seen {
      return package_contract_error(name, f"architectures repeats {architecture}")
    }

    seen[architecture] = true
  }
}

proc validate_dependencies(name: Str, label: Str, dependencies: List[Str]) {
  var seen: Map[Bool] = {}

  for dependency in dependencies {
    if dependency in seen {
      return package_contract_error(name, f"{label} contains duplicate dependency {dependency}")
    }

    if dependency == name {
      return package_contract_error(name, f"{label} may not depend on itself")
    }

    seen[dependency] = true
  }
}

# A runtime-only dependency is excluded from build roots and artifact keys, so
# a package the build also uses can never be runtime-only. Such a package is a
# `deps` entry (installed into the build root and needed at runtime).
proc validate_runtime_only_dependencies(name: Str, metadata: PackageMetadata) {
  validate_dependencies(name, "runtime_only_deps", metadata.runtime_only_deps)
  let build_dependencies = [@metadata.deps, @metadata.mkdeps_host, @metadata.mkdeps_target]

  for dependency in metadata.runtime_only_deps {
    if dependency in build_dependencies {
      return package_contract_error(
        name,
        f"runtime_only_deps entry {dependency} is also a build dependency; a package the build uses belongs in deps",
      )
    }
  }
}

proc source_is_repository_local(source: Path) -> Bool {
  let raw = source.display()
  ! util.is_url_source(raw) and ! raw.starts_with("/")
}

proc decode_source_checksum(name: Str, raw: Record) -> Result[types.SourceChecksum] {
  let arch: Str = raw.get("arch")?.require()?
  let sha256: Str = raw.get("sha256")?.require()?

  if arch != "aarch64" and arch != "all" and arch != "x86_64" {
    return Err(types.PmError.PackageContract(f"{name}: checksum has invalid architecture {arch}"))
  }

  if sha256 == "" {
    return Err(types.PmError.PackageContract(f"{name}: checksum for {arch} is empty"))
  }

  {arch, sha256}
}

proc decode_upstream_source(name: Str, raw: Record) -> Result[types.UpstreamSource] {
  let source: Path = raw.get("source")?.require()?
  let raw_kind: Str = raw.get("kind")?.require()?
  let kind = types.parse_source_kind(raw_kind)?
  let architectures: List[Str] = raw.get("architectures")?.require()?
  let raw_checksums: List[Record] = raw.get("checksums")?.require()?

  if architectures.len() == 0 {
    return Err(types.PmError.PackageContract(f"{name}: upstream source {source} has no target architectures"))
  }

  # A crate set replaces its destination directory, so it may not be the
  # source root that other sources stage into.
  if kind == types.source_cargo_vendor() and util.parse_source_line(source)?.dest.normalize() == "." {
    return Err(types.PmError.PackageContract(f"{name}: cargo-vendor source {source} needs a `=> DIR` destination"))
  }

  var architecture_seen: Map[Bool] = {}

  for architecture in architectures {
    if architecture in architecture_seen {
      return Err(types.PmError.PackageContract(f"{name}: upstream source {source} repeats architecture {architecture}"))
    }

    if architecture != "aarch64" and architecture != "x86_64" and architecture != "all" {
      return Err(
        types.PmError.PackageContract(
          f"{name}: upstream source {source} has unsupported architecture {architecture}",
        ),
      )
    }

    architecture_seen[architecture] = true
  }

  var checksums: List[types.SourceChecksum] = []
  var checksum_seen: Map[Bool] = {}

  for raw_checksum in raw_checksums {
    let checksum = decode_source_checksum(name, raw_checksum)?

    if checksum.arch in checksum_seen {
      return Err(types.PmError.PackageContract(f"{name}: upstream source {source} repeats {checksum.arch} checksum"))
    }

    if checksum.sha256 == "SKIP" and ! source_is_repository_local(source) {
      return Err(types.PmError.PackageContract(f"{name}: remote source {source} may not use SKIP"))
    }

    checksum_seen[checksum.arch] = true
    checksums += [checksum]
  }

  for target_arch in ["aarch64", "x86_64"] {
    continue unless target_arch in architectures or "all" in architectures
    var applicable_checksums = 0

    for checksum in checksums {
      if checksum.arch == target_arch or checksum.arch == "all" {
        applicable_checksums += 1
      }
    }

    if applicable_checksums != 1 {
      return Err(
        types.PmError.PackageContract(
          f"{name}: upstream source {source} needs exactly one {target_arch} or all checksum",
        ),
      )
    }
  }

  {source, kind, architectures, checksums}
}

proc decode_filetree_entry(name: Str, raw: Record) -> Result[types.FileTreeEntry] {
  let path_value: Path = raw.get("path")?.require()?
  let raw_kind: Str = raw.get("kind")?.require()?
  let kind = types.parse_file_kind(raw_kind)?
  let normalized = path_value.normalize()
  let raw_path = path_value.display()

  if raw_path == "" or normalized == "" or normalized == "." {
    return Err(types.PmError.PackageContract(f"{name}: filetree path must be nonempty"))
  }

  if raw_path != normalized.display() or raw_path.starts_with("/") or raw_path == ".." or raw_path.starts_with("../") or "/../" in raw_path {
    return Err(types.PmError.PackageContract(f"{name}: filetree path {raw_path} must be normalized and relative"))
  }

  {path: normalized, kind}
}

proc decode_upstream_sources(name: Str, raw_sources: List[Record]) -> Result[List[types.UpstreamSource]] {
  var sources: List[types.UpstreamSource] = [decode_upstream_source(name, raw_source)? for raw_source in raw_sources]
  sources
}

proc decode_filetree(name: Str, raw_entries: List[Record]) -> Result[List[types.FileTreeEntry]] {
  var entries: List[types.FileTreeEntry] = []
  var seen: Map[Bool] = {}

  for raw_entry in raw_entries {
    let entry = decode_filetree_entry(name, raw_entry)?
    let path_text = entry.path.display()

    if path_text in seen {
      return Err(types.PmError.PackageContract(f"{name}: filetree repeats {path_text}"))
    }

    seen[path_text] = true
    entries += [entry]
  }

  entries
}

# The recipe data contract. `.require` checks every present export's type, so
# an optional export read through `.get` can fail only by being absent, and
# its `??` fallback is that export's documented default.
type RecipeModule = module {
  export let name: Str
  export let ver: Str
  export let rel: Str
  export let deps: List[Str]
  export let mkdeps_host: List[Str]
  export let upstream_sources: List[Record]
  export let filetree: List[Record]
  export optional let mkdeps_target: List[Str]
  export optional let architectures: List[Str]
  export optional let runtime_only_deps: List[Str]
  export optional let filetree_aarch64: List[Record]
  export optional let filetree_x86_64: List[Record]
  export optional let package_kind: Str
  export optional let nostrip: Bool
  export optional let source_mirror: Bool
}

# The hook callers need only the recipe's identity; this contract makes the
# loaded module's exports readable by name, and each hook is then validated
# against its own capability contract.
type RecipeProcedures = module {
  export let name: Str
}

proc load_recipe_procedures(pkgbuild: Path) -> Result[RecipeProcedures] {
  module.load(pkgbuild)?.require(RecipeProcedures).context("package-load", pkgbuild.display())?
}

proc load_recipe_module(pkgbuild: Path) -> Result[RecipeModule] {
  module.load(pkgbuild)?.require(RecipeModule).context("package-load", pkgbuild.display())?
}

pure select_filetree(metadata: PackageMetadata, arch: Str) -> List[Record] {
  if arch == "aarch64" and metadata.has_filetree_aarch64 {
    return metadata.filetree_aarch64
  }

  return metadata.filetree_x86_64 when arch == "x86_64" and metadata.has_filetree_x86_64

  metadata.filetree
}

proc is_production_recipe_directory(dir: Path) -> Bool {
  dir.parent.name == "repo"
}

proc decode_metadata(pkgbuild: Path) -> Result[PackageMetadata] {
  let recipe = load_recipe_module(pkgbuild)?
  let has_build = recipe.get("build") is Ok(_)
  let has_filetree_aarch64 = recipe.get("filetree_aarch64") is Ok(_)
  let has_filetree_x86_64 = recipe.get("filetree_x86_64") is Ok(_)
  let has_package_kind = recipe.get("package_kind") is Ok(_)
  let name = recipe.name
  let ver = recipe.ver
  let rel = recipe.rel
  let deps = recipe.deps
  let mkdeps_host = recipe.mkdeps_host
  let upstream_sources = recipe.upstream_sources
  let filetree = recipe.filetree
  let mkdeps_target: List[Str] = recipe.get("mkdeps_target") ?? []
  # A recipe without an `architectures` export exists for every supported target.
  let architectures: List[Str] = recipe.get("architectures") ?? ["aarch64", "x86_64"]
  let runtime_only_deps: List[Str] = recipe.get("runtime_only_deps") ?? []
  let filetree_aarch64: List[Record] = recipe.get("filetree_aarch64") ?? []
  let filetree_x86_64: List[Record] = recipe.get("filetree_x86_64") ?? []
  let package_kind: Str = recipe.get("package_kind") ?? ""
  let nostrip: Bool = recipe.get("nostrip") ?? false
  let source_mirror: Bool = recipe.get("source_mirror") ?? true

  {
    name,
    ver,
    rel,
    architectures,
    deps,
    runtime_only_deps,
    mkdeps_host,
    mkdeps_target,
    upstream_sources,
    filetree,
    filetree_aarch64,
    has_filetree_aarch64,
    filetree_x86_64,
    has_filetree_x86_64,
    has_build,
    package_kind,
    has_package_kind,
    nostrip,
    source_mirror,
  }
}

## Loads, decodes, and validates one package recipe into its typed metadata record.
export proc load_package_for_target(dir: Path, target: types.Target) [fs, env, error] -> Result[types.Package, Error] {
  let arch = types.pm_target_arch(target)
  if arch == "" {
    return Err(types.PmError.PackageContract("recipe target is unsupported"))
  }

  let pkgbuild = fp"{dir}/PKGBUILD.xsh"

  if ! pkgbuild.exists()? {
    return Err(types.PmError.PackageContract(f"{dir} does not contain PKGBUILD.xsh"))
  }

  let metadata = decode_metadata(pkgbuild).context("package-load", pkgbuild.display())?
  let {name, ver, rel, mkdeps_target, nostrip, source_mirror, ..} = metadata

  validate_package_name(name)

  if ver == "" {
    return Err(types.PmError.PackageContract(f"{name}: ver must be nonempty"))
  }

  validate_positive_release(name, rel)
  validate_package_architectures(name, metadata.architectures)
  validate_dependencies(name, "deps", metadata.deps)
  validate_dependencies(name, "mkdeps_host", metadata.mkdeps_host)
  validate_dependencies(name, "mkdeps_target", mkdeps_target)
  validate_runtime_only_dependencies(name, metadata)

  if is_production_recipe_directory(dir) and dir.name != name {
    return Err(
      types.PmError.PackageContract(f"{name}: production recipe directory {dir.name} does not match package name"),
    )
  }

  if is_production_recipe_directory(dir) and ! metadata.has_package_kind {
    return Err(types.PmError.PackageContract(f"{name}: production recipe must export package_kind"))
  }

  let kind = if metadata.has_package_kind {
    types.parse_package_kind(metadata.package_kind)?
  } else {
    types.package_payload()
  }
  let upstream_sources = decode_upstream_sources(name, metadata.upstream_sources)?
  let filetree = decode_filetree(name, select_filetree(metadata, arch))?

  if kind == types.package_payload() {
    guard metadata.has_build else {
      return Err(types.PmError.PackageContract(f"{name}: payload package must export build"))
    }

    if ! fp"{dir}/proof.xsh".exists()? {
      return Err(types.PmError.PackageContract(f"{name}: payload package must contain proof.xsh"))
    }
  } else if filetree.len() > 0 {
    return Err(types.PmError.PackageContract(f"{name}: metapackage may not declare payload filetree entries"))
  }

  {
    dir,
    name,
    ver,
    rel,
    kind,
    architectures: metadata.architectures,
    deps: metadata.deps,
    runtime_only_deps: metadata.runtime_only_deps,
    mkdeps_host: metadata.mkdeps_host,
    mkdeps_target,
    upstream_sources,
    filetree,
    nostrip,
    source_mirror,
  }
}

## Loads a recipe using the ambient target architecture for legacy PM callers.
export proc load_package(dir: Path) [fs, env, error] -> Result[types.Package, Error] {
  load_package_for_target(dir, types.parse_target(util.machine_arch()?)?)?
}

proc dynamic_recipe_path(pkg: types.Package) -> Result[Path] {
  let pkgbuild = fp"{pkg.dir}/PKGBUILD.xsh"

  if ! pkgbuild.exists()? {
    return Err(types.PmError.PackageContract(f"{pkg.name}: dynamic recipe is unavailable at {pkgbuild}"))
  }

  pkgbuild
}

## Invokes the optional dynamic `prepare` procedure for a loaded package.
export proc call_prepare(pkg: types.Package, src: Path) [fs, process, env, error] {
  let dynamic = load_recipe_procedures(dynamic_recipe_path(pkg)?)?

  return unless dynamic.get("prepare") is Ok(_)

  if let Ok(filesystem_hook) = dynamic.require(hooks.PrepareFilesystem) {
    filesystem_hook.prepare(src)
    return
  }

  if let Ok(environment_hook) = dynamic.require(hooks.PrepareFilesystemEnvironment) {
    environment_hook.prepare(src)
    return
  }

  if let Ok(process_hook) = dynamic.require(hooks.PrepareProcessesEnvironment) {
    process_hook.prepare(src)
    return
  }

  let prepare_hook = dynamic.require(hooks.PrepareFilesystemProcessesEnvironment)?
  prepare_hook.prepare(src)
}

## Invokes the required payload `build` procedure through the dynamic recipe boundary.
export proc call_build(pkg: types.Package, src: Path, dest: Path) [fs, process, env, error] {
  return when pkg.kind == types.package_meta()

  let dynamic = load_recipe_procedures(dynamic_recipe_path(pkg)?)?

  if ! (dynamic.get("build") is Ok(_)) {
    return Err(types.PmError.PackageContract(f"{pkg.name}: payload package lost its build procedure"))
  }

  if let Ok(filesystem_hook) = dynamic.require(hooks.BuildFilesystem) {
    cd src { filesystem_hook.build(dest) }
    return
  }

  if let Ok(environment_hook) = dynamic.require(hooks.BuildFilesystemEnvironment) {
    cd src { environment_hook.build(dest) }
    return
  }

  if let Ok(process_hook) = dynamic.require(hooks.BuildProcessesEnvironment) {
    cd src { process_hook.build(dest) }
    return
  }

  let build_hook = dynamic.require(hooks.BuildFilesystemProcessesEnvironment)?
  cd src { build_hook.build(dest) }
}

## Invokes the optional dynamic `prepare_sources` procedure for a loaded package.
export proc call_prepare_sources(pkg: types.Package, src: Path) [fs, process, env, error] {
  let dynamic = load_recipe_procedures(dynamic_recipe_path(pkg)?)?

  if dynamic.get("prepare_sources") is Ok(_) {
    let sources_hook = dynamic.require(hooks.PrepareSourcesFilesystem)?
    sources_hook.prepare_sources(src)
  }
}
