##! Exact semantic fingerprints for package inputs and executor provenance.
use types
use util

pure canonical_field(value: Str) -> Str {
  value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")
}

pure ignored_tree_path(rel: Path) -> Bool {
  let key = rel.display()
  key == ".git" or key.starts_with(".git/") or key == ".work" or key.starts_with(".work/") or key == "work" or key.starts_with(
    "work/",
  )
}

pure package_input_path(rel: Path) -> Bool {
  return false when ignored_tree_path(rel) or rel.name == "proof.xsh"

  let key = rel.display()
  rel.name.ends_with(".xsh") or key == "files" or key.starts_with("files/") or key == "patches" or key.starts_with(
    "patches/",
  )
}

proc tree_entry_line(root: Path, path_value: Path, prefix: Str) -> Result[Str] {
  let rel = path_value.strip_prefix(root)?
  let metadata = path_value.metadata()?
  let label = canonical_field(rel.display())
  let mode = util.checkout_mode(metadata.kind, metadata.mode)

  match metadata.kind {
    "file" => f"{prefix}\tfile\t{label}\t{mode}\t{hash.sha256(path_value)?.hex()}"
    "symlink" => f"{prefix}\tsymlink\t{label}\t{canonical_field(path_value.readlink()?.display())}"
    "dir" => f"{prefix}\tdir\t{label}\t{mode}"
    else => f"{prefix}\t{metadata.kind}\t{label}\t{metadata.mode % 4096}\t{metadata.size}"
  }
}

proc digest_lines(lines: List[Str]) [error] -> Result[Str] {
  bytes.from_text((lines |> sort).join("\n") + "\n").sha256().hex()
}

pure applicable_checksum(source: types.UpstreamSource, target: types.Target) -> Result[Str] {
  let arch = types.pm_target_arch(target)
  var all_checksum = ""

  for checksum in source.checksums {
    return checksum.sha256 when checksum.arch == arch

    if checksum.arch == "all" {
      all_checksum = checksum.sha256
    }
  }

  return all_checksum when all_checksum != ""

  Err(types.PmError.PackageContract(f"{source.source} has no checksum for {arch}"))
}

# Returns whether a relative symlink target, resolved lexically from the link's
# own directory, stays inside the tree that contains the link at `rel`.
pure symlink_target_stays_within(rel: Path, target: Str) -> Bool {
  return false when target == "" or target.starts_with("/")

  var depth = rel.display().split("/").len() - 1

  for component in target.split("/") {
    continue when component == "" or component == "."

    if component == ".." {
      return false when depth == 0

      depth -= 1
    } else {
      depth += 1
    }
  }

  true
}

# The digest records a symlink by its target text and never follows it, so a
# link out of the recipe directory would let content outside the digest reach
# a build (staging copies the recipe tree) or a module import. Recipes name
# shared code through the module path and outside inputs as `repository/`
# sources instead.
proc package_source_lines(pkg: types.Package) -> Result[List[Str]] {
  var lines: List[Str] = []

  for entry in fs.walk(pkg.dir) |> sort-by .path {
    let rel = entry.path.strip_prefix(pkg.dir)?
    continue when ignored_tree_path(rel)

    if entry.kind == "symlink" {
      let target = entry.path.readlink()?.display()

      if ! symlink_target_stays_within(rel, target) {
        return Err(
          types.PmError.PackageContract(f"{pkg.name}: recipe symlink {rel} -> {target} leaves the recipe directory"),
        )
      }
    }

    if package_input_path(rel) {
      lines += [tree_entry_line(pkg.dir, entry.path, "package-file")?]
    }
  }

  lines
}

# Repository inputs are explicit recipe declarations, but live outside the
# recipe directory. Hash their complete declared file/tree contents so a PM
# module edit changes laputa-pm's package build identity without recording an
# absolute checkout path.
#
# Only the sources the target stages are hashed, after the same placeholder
# expansion staging applies, so `repository/.out/seed/ARCH` keys each target by
# its own seed and another target's inputs never change this key. Builds are
# native, so the build architecture is the target's.
proc repository_input_lines(
  repo_root: Path,
  pkg: types.Package,
  target: types.Target,
) -> Result[List[Str]] {
  let arch = types.pm_target_arch(target)
  var lines: List[Str] = []

  for source in pkg.upstream_sources {
    continue unless arch in source.architectures or "all" in source.architectures
    let parsed = util.parse_source_line(source.source)?
    let expanded = util.expand_source(parsed.source, pkg, arch, arch)

    continue unless expanded.starts_with("repository/")
    let relative = fp"{expanded.replace("repository/", "")}".normalize()
    let _ = util.ensure_relative_path(relative, f"repository source {expanded}")?
    let input = fp"{repo_root}/{relative}"

    if ! input.exists() {
      return Err(types.PmError.PackageContract(f"{pkg.name}: repository source {expanded} is missing"))
    }

    if input.is_dir() {
      for entry in fs.walk(input) |> sort-by .path {
        let rel = entry.path.strip_prefix(repo_root)?

        if ! ignored_tree_path(rel) {
          lines += [tree_entry_line(repo_root, entry.path, "repository-input")?]
        }
      }
    } else {
      lines += [tree_entry_line(repo_root, input, "repository-input")?]
    }
  }

  lines
}

## Hashes every semantic package build input without absolute checkout state or modification times.
export proc package_build_input(repo_root: Path, pkg: types.Package, target: types.Target) [fs, error] -> Result[Str, Error] {
  if types.pm_target_arch(target) == "" {
    return Err(types.PmError.PackageContract("package build input target is unsupported"))
  }

  var lines = [
    "format\tlaputa-package-build-input-1",
    f"package\t{canonical_field(pkg.name)}\t{canonical_field(pkg.ver)}\t{canonical_field(pkg.rel)}",
    f"package-kind\t{types.package_kind_text(pkg.kind)}",
    f"target\t{types.target_text(target)}",
    f"nostrip\t{pkg.nostrip}",
  ]

  for dependency in pkg.deps {
    lines += [f"dependency\t{types.dependency_kind_text(types.dependency_runtime())}\t{canonical_field(dependency)}"]
  }

  for dependency in pkg.runtime_only_deps {
    lines += [
      f"dependency\t{types.dependency_kind_text(types.dependency_runtime_only())}\t{canonical_field(dependency)}",
    ]
  }

  for dependency in pkg.mkdeps_host {
    lines += [f"dependency\t{types.dependency_kind_text(types.dependency_build_host())}\t{canonical_field(dependency)}"]
  }

  for dependency in pkg.mkdeps_target {
    lines += [
      f"dependency\t{types.dependency_kind_text(types.dependency_build_target())}\t{canonical_field(dependency)}",
    ]
  }

  for source in pkg.upstream_sources {
    continue unless types.pm_target_arch(target) in source.architectures or "all" in source.architectures
    lines += [
      f"source\t{canonical_field(source.source.display())}\t{types.source_kind_text(source.kind)}\t{canonical_field(applicable_checksum(source, target)?)}",
    ]
  }

  for entry in pkg.filetree {
    lines += [f"filetree\t{canonical_field(entry.path.display())}\t{types.file_kind_text(entry.kind)}"]
  }

  lines += package_source_lines(pkg)?
  lines += repository_input_lines(repo_root, pkg, target)?
  digest_lines(lines)?
}

proc pm_proof_module(pm_root: Path) -> Result[Str] {
  let proof = fp"{pm_root}/pm/proof.xsh"

  if ! proof.exists() {
    return Err(types.PmError.PackageContract(f"{proof} is missing"))
  }

  hash.sha256(proof)?.hex()
}

## Hashes proof-only inputs independently from build inputs so an unchanged artifact can be re-proved.
export proc package_proof_input(repo_root: Path, pkg: types.Package) [fs, error] -> Result[Str, Error] {
  let proof = fp"{pkg.dir}/proof.xsh"
  let proof_sha256 = if proof.exists() { hash.sha256(proof)?.hex() } else { "missing" }
  digest_lines(
    [
      "format\tlaputa-package-proof-input-1",
      f"package\t{canonical_field(util.package_id(pkg.name, pkg.ver, pkg.rel))}",
      f"proof\t{proof_sha256}",
      f"pm-proof\t{pm_proof_module(repo_root)?}",
    ],
  )?
}

## Hashes the PM entrypoint and every implementation module below `pm/`.
export proc pm_tree(pm_root: Path) [fs, error] -> Result[Str, Error] {
  let entrypoint = fp"{pm_root}/pm.xsh"
  let modules = fp"{pm_root}/pm"

  if ! entrypoint.exists() or ! modules.exists() {
    return Err(types.PmError.PackageContract(f"{pm_root} is not a PM source root"))
  }

  var lines = ["format\tlaputa-pm-tree-1", tree_entry_line(pm_root, entrypoint, "pm")?]

  for entry in fs.walk(modules) |> sort-by .path {
    let rel = entry.path.strip_prefix(pm_root)?

    if ! ignored_tree_path(rel) and entry.kind != "dir" and entry.path.name.ends_with(".xsh") {
      lines += [tree_entry_line(pm_root, entry.path, "pm")?]
    }
  }

  digest_lines(lines)?
}

## Hashes mounted XSH core applets by relative path, mode, and contents.
export proc core_tree(core_root: Path) [fs, error] -> Result[Str, Error] {
  guard core_root.exists() else {
    return Err(types.PmError.PackageContract(f"{core_root} is missing"))
  }

  var lines = ["format\tlaputa-core-tree-1"]

  for entry in fs.walk(core_root) |> sort-by .path {
    let rel = entry.path.strip_prefix(core_root)?

    if ! ignored_tree_path(rel) and rel != "" {
      lines += [tree_entry_line(core_root, entry.path, "core")?]
    }
  }

  digest_lines(lines)?
}

## Digests an executor provenance record for receipts and repository metadata.
export proc executor_provenance_sha256(value: types.ExecutorProvenance) [error] -> Result[Str, Error] {
  digest_lines(
    [
      f"format\t{canonical_field(value.format)}",
      f"runner\txsh\t{canonical_field(value.xsh_sha256)}",
      f"runner\txshi\t{canonical_field(value.xshi_sha256)}",
      f"runner\txsht\t{canonical_field(value.xsht_sha256)}",
      f"pm\t{canonical_field(value.pm_sha256)}",
      f"core\t{canonical_field(value.core_sha256 ?? "none")}",
    ],
  )?
}
