##! PM local operations and shared package-manager policy.
use elf
use recipe
use sources
use types
use util

type PackageFileTreeEntryDto = {path: Str, kind: Str}

type PackageFileEntryDto = {path: Str, kind: Str, mode: Int, sha256: Str, target: Str}

## JSON metadata emitted for one prepared package payload, using string wire kinds and paths.
export type PackageMetadataDto = {
  arch: Str,
  name: Str,
  ver: Str,
  rel: Str,
  deps: List[Str],
  runtime_only_deps: List[Str],
  mkdeps_host: List[Str],
  mkdeps_target: List[Str],
  filetree: List[PackageFileTreeEntryDto],
  manifest: List[Str],
  metadata_sha256: Str,
  package_kind: Str,
  files: List[PackageFileEntryDto],
}

## Exported PM declaration `collect_manifest_text`.
export pure collect_manifest_text(manifest: List[Path]) -> Result[List[Str], Error] {
  let lines = [rel_path.display() for rel_path in manifest]
  lines
}

## Exported PM declaration `load_manifest`.
export proc load_manifest(db: Path) [fs, error] -> Result[List[Path], Error] {
  var manifest = []

  if fp"{db}/manifest.json".exists() {
    let stored: List[Str] = json.read(fp"{db}/manifest.json")?.require()?

    for rel_text in stored {
      manifest += [fp"{rel_text}"]
    }
  }

  manifest
}

## Exported PM declaration `collect_etcsums`.
export proc collect_etcsums(dest: Path, manifest: List[Path]) [fs, error] -> Result[List[types.EtcSum], Error] {
  let sums = collect {
    for rel_path in manifest {
      if util.is_etc_file(rel_path) {
        let meta = fp"{dest}/{rel_path}".metadata()?

        if meta.kind == "file" {
          let sha256 = hash.sha256(fp"{dest}/{rel_path}")?.hex()
          yield {path: rel_path.display(), sha256}
        }
      }
    }
  }

  sums
}

## Exported PM declaration `validate_and_strip_package`.
export proc validate_and_strip_package(pkg: types.Package, dest: Path, manifest: List[Path]) [fs, process, error] {
  var declared: Map[types.FileKind] = {}
  let binaries = collect {
    for entry in pkg.filetree {
      let key = entry.path.display()

      if key == "" or key.starts_with("/") or key.starts_with("../") or "/../" in key {
        return Err(types.PmError.PackageContract(f"{pkg.name} declares an invalid filetree path {key}"))
      }

      if key in declared {
        return Err(types.PmError.PackageContract(f"{pkg.name} declares {key} more than once"))
      }

      declared[key] = entry.kind

      if entry.kind == types.file_kind_binary() {
        yield entry.path
      }

      if entry.kind == types.file_kind_tree() {
        guard fp"{dest}/{entry.path}".is_dir() else {
          return Err(types.PmError.PackageContract(f"{pkg.name} declares {key} as a tree, but it is not a directory"))
        }
      }
    }
  }

  for rel_path in manifest {
    let key = rel_path.display()
    let path_value = fp"{dest}/{rel_path}"
    let actual_kind = path_value.metadata()?.kind
    if ! (key in declared) {
      var covered_by_tree = false

      for entry in pkg.filetree {
        let tree = entry.path.display()

        if entry.kind == types.file_kind_tree() and key.starts_with(f"{tree}/") {
          covered_by_tree = true
        }
      }

      if ! covered_by_tree {
        return Err(types.PmError.PackageContract(f"{pkg.name} built undeclared file {key}"))
      }

      if actual_kind == "symlink" {
        return Err(types.PmError.PackageContract(f"{pkg.name} symlink {key} must be declared explicitly"))
      }

      match elf.inspect(path_value) {
        Ok(info) if info.type != "not-elf" => return Err(
          types.PmError.PackageContract(f"{pkg.name} ELF output {key} must be declared as binary"),
        )
        Ok(_) => {}
        Err(_) => {}
      }

      continue
    }

    let declared_kind = declared.get(key)?

    if declared_kind == types.file_kind_tree() {
      return Err(types.PmError.PackageContract(f"{pkg.name} filetree tree {key} overlaps an output file"))
    }

    if declared_kind == types.file_kind_symlink() {
      guard actual_kind == "symlink" else {
        return Err(types.PmError.PackageContract(f"{pkg.name} declares {key} as a symlink, found {actual_kind}"))
      }

      continue
    }

    if actual_kind != "file" {
      return Err(
        types.PmError.PackageContract(
          f"{pkg.name} declares {key} as {types.file_kind_text(declared_kind)}, found {actual_kind}",
        ),
      )
    }

    match elf.inspect(path_value) {
      Ok(info) if info.type != "not-elf" and declared_kind == types.file_kind_file() => return Err(
        types.PmError.PackageContract(f"{pkg.name} ELF output {key} must be declared as binary"),
      )
      Ok(info) if info.type == "not-elf" and declared_kind == types.file_kind_binary() => return Err(
        types.PmError.PackageContract(f"{pkg.name} declares non-ELF output {key} as binary"),
      )
      Ok(_) => {}
      Err(_) if declared_kind == types.file_kind_binary() => return Err(
        types.PmError.PackageContract(f"{pkg.name} declares non-ELF output {key} as binary"),
      )
      Err(_) => {}
    }
  }

  for entry in pkg.filetree {
    let key = entry.path.display()

    if entry.kind != types.file_kind_tree() and ! fp"{dest}/{entry.path}".exists() {
      return Err(types.PmError.PackageContract(f"{pkg.name} declares missing file {key}"))
    }
  }

  return when pkg.nostrip or binaries.is_empty()

  let strip = process.which("llvm-strip")?

  for rel_path in binaries {
    run $strip "--strip-unneeded" fp"{dest}/{rel_path}"
  }
}

## Exported PM declaration `collect_metadata_files`.
export proc collect_metadata_files(root: Path, manifest: List[Path]) [fs, error] -> Result[List[types.ArtifactEntry], Error] {
  let root_handle = fs.open_root(root)?
  defer root_handle.close()

  let files: List[types.ArtifactEntry] = collect {
    for rel_path in manifest {
      if let Ok(target) = root_handle.readlink(rel_path) {
        yield {
          path: rel_path.display(),
          kind: types.file_kind_symlink(),
          mode: 0o777,
          sha256: "",
          target: target.display(),
        }

        continue
      }

      let meta = root_handle.metadata(rel_path)?
      var sha256 = ""

      if meta.kind == "file" {
        sha256 = root_handle.read_bytes(rel_path)?.sha256().hex()
      }

      var kind = types.file_kind_file()

      match meta.kind {
        "file" => kind = types.file_kind_file()
        "dir" => kind = types.file_kind_tree()
        else => return Err(types.PmError.PackageContract(f"metadata cannot represent {rel_path} as {meta.kind}"))
      }

      yield {path: rel_path.display(), kind, mode: meta.mode % 4096, sha256, target: ""}
    }
  }

  files
}

## Exported PM declaration `collect_archive_paths`.
## Defines the exact payload inventory shared by archive creation and receipt metadata.
## Empty directories created incidentally by a package build remain payload entries: omitting them
## from the archive would make a verified receipt describe a root that cannot be materialized.
export proc collect_archive_paths(root: Path, filetree: List[types.FileTreeEntry]) [fs, error] -> Result[List[Path], Error] {
  var entries: List[Path] = []
  let root_text = root.display()

  for entry in fs.walk(root) {
    var include = entry.kind == "file" or entry.kind == "symlink"

    if entry.kind == "dir" and entry.path.display() != root_text and dir_empty(entry.path) {
      include = true
    }

    if include {
      entries += [entry.path.strip_prefix(root)?]
    }
  }

  # `fs.walk` is the general inventory, but an explicitly declared empty
  # directory is a durable payload member even when the walker did not report
  # it.  Recording it here keeps receipt metadata exactly aligned with the
  # archive assembled by `pm.build`.
  for entry in filetree {
    if entry.kind == types.file_kind_tree() {
      let tree = fp"{root}/{entry.path}"

      if dir_empty(tree) {
        entries += [entry.path]
      }
    }
  }

  var unique: Set[Str] = set.empty()
  let canonical: List[Path] = collect {
    for entry in entries |> sort-by .display() {
      let key = entry.display()

      if ! (key in unique) {
        unique = unique.add(key)
        yield entry
      }
    }
  }

  canonical
}

## Exported PM declaration `collect_artifact_entries`.
## Captures the exact archive inventory as immutable artifact metadata.
export proc collect_artifact_entries(
  root: Path,
  filetree: List[types.FileTreeEntry],
) [fs, error] -> Result[List[types.ArtifactEntry], Error] {
  let canonical = collect_archive_paths(root, filetree)?
  collect_metadata_files(root, canonical)?
}

## Exported PM declaration `metadata_files_sha256`.
export proc metadata_files_sha256(pkg: types.Package, files: List[types.ArtifactEntry]) [error] -> Result[Str, Error] {
  var body = f"""name	{pkg.name}
ver	{pkg.ver}
deps	{pkg.deps.join(" ")}
mkdeps_host	{pkg.mkdeps_host.join(" ")}
"""

  if ! pkg.mkdeps_target.is_empty() {
    body = f"""{body}mkdeps_target	{pkg.mkdeps_target.join(" ")}
"""
  }

  for entry in pkg.filetree {
    body = f"""{body}filetree	{entry.path}	{types.file_kind_text(entry.kind)}
"""
  }

  for file in files {
    body = f"""{body}{file.path}	{types.file_kind_text(file.kind)}	{file.mode}	{file.sha256}	{file.target}
"""
  }

  bytes.from_text(body).sha256().hex()
}

## Writes artifact metadata: the package inventory plus the executor that built it.
## `executor` is provenance for readers; the typed DTO leaves it out so metadata
## written before it existed still decodes.
export proc write_package_metadata(
  path_value: Path,
  arch: Str,
  item: types.BuiltPackage,
  executor: types.ExecutorProvenance,
) [fs, error] {
  path_value.parent.mkdir()
  let manifest = collect_manifest_text(item.manifest)?

  let metadata: PackageMetadataDto = PackageMetadataDto(
    arch:,
    name: item.pkg.name,
    ver: item.pkg.ver,
    rel: item.pkg.rel,
    deps: item.pkg.deps,
    runtime_only_deps: item.pkg.runtime_only_deps,
    mkdeps_host: item.pkg.mkdeps_host,
    mkdeps_target: item.pkg.mkdeps_target,
    filetree: [
      {path: entry.path.display(), kind: types.file_kind_text(entry.kind)}
      for entry in item.pkg.filetree
    ],
    manifest:,
    metadata_sha256: item.metadata_sha256,
    package_kind: types.package_kind_text(item.pkg.kind),
    files: [
      {
        path: entry.path,
        kind: types.file_kind_text(entry.kind),
        mode: entry.mode,
        sha256: entry.sha256,
        target: entry.target,
      }
      for entry in item.metadata_files
    ],
  )
  json.write(path_value, {...metadata, executor})
}

## Exported PM declaration `dir_empty`.
export proc dir_empty(path_value: Path) [fs, error] -> Result[Bool, Error] {
  for _ in fs.children(path_value)? {
    return false
  }

  true
}

## Exported PM declaration `write_package_db`.
export proc write_package_db(
  root: Path,
  pkg: types.Package,
  manifest: List[Path],
  etcsums: List[types.EtcSum],
) [fs, error] {
  let db = util.package_db_path(root, pkg.name)
  db.mkdir()
  let manifest_text = collect_manifest_text(manifest)?
  json.write(fp"{db}/manifest.json", manifest_text)
  json.write(fp"{db}/etcsums.json", etcsums)

  json.write(
    fp"{db}/metadata.json",
    {
      name: pkg.name,
      ver: pkg.ver,
      rel: pkg.rel,
      deps: pkg.deps,
      mkdeps_host: pkg.mkdeps_host,
      mkdeps_target: pkg.mkdeps_target,
      package_kind: types.package_kind_text(pkg.kind),
      filetree: [{path: entry.path.display(), kind: types.file_kind_text(entry.kind)} for entry in pkg.filetree],
      nostrip: pkg.nostrip,
      dir: pkg.dir.display(),
    },
  )
}

## Exported PM declaration `load_package_dirs`.
export proc load_package_dirs(dirs: List[Path]) [fs, env, error] -> Result[List[types.Package], Error] {
  var seen: Set[Str] = set.empty()

  let packages = collect {
    for dir in dirs {
      let pkg = recipe.load_package(dir)?

      if pkg.name in seen {
        return Err(types.PmError.PackageContract(f"duplicate package {pkg.name}"))
      }

      seen = seen.add(pkg.name)
      yield pkg
    }
  }

  packages
}

## Exported PM declaration `load_built_package_from_dest`.
export proc load_built_package_from_dest(
  pkg: types.Package,
  id: Str,
  tarball: Path,
  dest: Path,
) [fs, error] -> Result[types.BuiltPackage, Error] {
  if pkg.kind == types.package_meta() {
    let metadata_files: List[types.ArtifactEntry] = []

    return {
      pkg,
      id,
      tarball,
      manifest: [],
      etcsums: [],
      metadata_sha256: metadata_files_sha256(pkg, metadata_files)?,
      metadata_files,
    }
  }

  let db = util.package_db_path(dest, pkg.name)
  let manifest = load_manifest(db)?
  let etcsums: List[types.EtcSum] = json.read(fp"{db}/etcsums.json")?.require()?
  let metadata_files = collect_artifact_entries(dest, pkg.filetree)?
  let metadata_sha256 = metadata_files_sha256(pkg, metadata_files)?

  {
    pkg,
    id,
    tarball,
    manifest,
    etcsums,
    metadata_sha256,
    metadata_files,
  }
}

## Exported PM declaration `print_package_checksums`.
export proc print_package_checksums(cache_root: Path, pkg: types.Package) [fs, net, env, error] {
  let arch = util.machine_arch()?
  let generated = sources.generate_checksums_for(cache_root, pkg, arch)?

  for checksum in generated {
    print ${pkg.name} $checksum
  }
}

## Exported PM declaration `update_package_checksums`.
export proc update_package_checksums(cache_root: Path, pkg: types.Package) [fs, net, env, error] {
  let updates = sources.collect_checksum_updates(cache_root, pkg)?

  for update in updates {
    sources.write_checksum_field(pkg, update.field, update.values)
    print ${pkg.name} ${update.field} updated
  }
}
