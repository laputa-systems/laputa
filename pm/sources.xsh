##! PM sources operations and shared package-manager policy.
use recipe
use types
use util

# `repository/` names a declared package-repository input rather than a path
# relative to an isolated recipe copy. The executor supplies its exact
# repository root, so recipes can stage repository-owned source trees without
# `..` traversal or an ambient working directory.
pure sources_is_repository_input(source: Str) -> Bool {
  source.starts_with("repository/")
}

proc sources_repository_input_path(source: Str) [fs, env, error] -> Result[Path] {
  let root = (e"XSH_PM_REPOSITORY_ROOT" ?? "").trim()
  let relative = fp"{source.replace("repository/", "")}".normalize()

  if root == "" {
    return Err(types.PmError.PackageContract(f"repository source {source} needs XSH_PM_REPOSITORY_ROOT"))
  }

  let _ = util.ensure_relative_path(relative, f"repository source {source}")?
  fp"{root}/{relative}"
}

## Exported PM declaration `ensure_source_dest`.
export pure ensure_source_dest(dest: Path) -> Result[Unit, Error] {
  let _ = util.ensure_relative_path(dest, "source destination")?
}

## Exported PM declaration `source_checksum`.
export proc source_checksum(source: types.UpstreamSource, arch: Str) [error] -> Result[Str, Error] {
  for checksum in source.checksums {
    return checksum.sha256 when checksum.arch == arch or checksum.arch == "all"
  }

  Err(types.PmError.SourceChecksum(f"no checksum for {source.source} on {arch}"))
}

# URL sources are content-addressed: `make fetch` (`pm sources fetch`) is the
# only step that contacts upstream hosts. Builds resolve a pinned URL source from
# the cache, then from the local mirror named by LAPUTA_MIRROR, and otherwise
# fail. The source string and checksum stay the recipe's identity, so where the
# bytes come from never changes a fingerprint.
const sha256_hex = rx"^[0-9a-f]{64}$"

## The source cache root for a package repository: LAPUTA_SOURCE_CACHE when set,
## otherwise `.cache/sources` under the repository root.
export proc source_cache_root(repo_root: Path) [fs, env, error] -> Result[Path, Error] {
  let configured = (e"LAPUTA_SOURCE_CACHE" ?? "").trim()

  return path.absolute(fp"{configured}")? when configured != ""

  fp"{repo_root}/.cache/sources"
}

# Builds name their package repository through XSH_PM_REPOSITORY_ROOT, the same
# root that `repository/` inputs resolve against.
proc build_source_cache_root() [fs, env, error] -> Result[Path] {
  let configured = (e"LAPUTA_SOURCE_CACHE" ?? "").trim()
  let repo_root = (e"XSH_PM_REPOSITORY_ROOT" ?? "").trim()

  if configured == "" and repo_root == "" {
    return Err(
      types.PmError.SourceNotFound(
        "URL sources need LAPUTA_SOURCE_CACHE or XSH_PM_REPOSITORY_ROOT to locate the source cache",
      ),
    )
  }

  source_cache_root(fp"{repo_root}")?
}

## The cache entry for one sha256, the layout the local mirror serves at `/sources/sha256/<hash>`.
export pure source_cache_entry(root: Path, sha256: Str) -> Path {
  fp"{root}/sha256/{sha256}"
}

## The local mirror URL for one cached source.
export pure mirror_source_url(mirror: Str, sha256: Str) -> Str {
  var base = mirror.trim()

  while base.ends_with("/") {
    base = base.byte_slice(0, base.byte_len() - 1)
  }

  f"{base}/sources/sha256/{sha256}"
}

## Validates the pin a URL source is cached under. `SKIP` is only for repository-local sources.
export pure pinned_url_sha256(package_name: Str, url: Str, checksum: Str) -> Result[Str, Error] {
  if checksum == "SKIP" {
    return Err(
      types.PmError.SourceChecksum(
        f"{package_name} URL source {url} must pin a sha256; SKIP is only for repository-local sources",
      ),
    )
  }

  if ! sha256_hex.matches(checksum) {
    return Err(types.PmError.SourceChecksum(f"{package_name} URL source {url} has a malformed sha256 {checksum}"))
  }

  checksum
}

## How filling one source cache entry ended.
export enum SourceFetchOutcome { Cached, Fetched(Int), Unavailable(Str), Mismatch(Str) }

## Downloads `url` into the cache entry for `sha256`, publishing only verified bytes.
export proc fill_source_cache_entry(root: Path, sha256: Str, url: Str) [fs, net, error] -> Result[SourceFetchOutcome, Error] {
  let entry = source_cache_entry(root, sha256)
  let partial_dir = fp"{root}/partial"
  fs.mkdir(entry.parent)?
  fs.mkdir(partial_dir)?
  # Packages built in parallel can share one source, so one writer fills an entry.
  let lock = fs.lock(fp"{partial_dir}/{sha256}.lock")?
  defer fs.unlock(lock)?

  return Cached when fs.exists(entry)?

  let partial = fp"{partial_dir}/{sha256}"
  fs.remove(partial, missing_ok: true)?
  defer fs.remove(partial, missing_ok: true)?
  let failure = util.download_file(url, partial)?

  return Unavailable(failure) when failure != ""

  let actual = hash.sha256(partial)?.hex()

  return Mismatch(f"{url}: expected sha256 {sha256}, got {actual}") when actual != sha256

  let size = fs.metadata(partial)?.size
  fs.rename(partial, entry)?
  Fetched(size)
}

proc resolve_url_source(package_name: Str, url: Str, checksum: Str) [fs, net, env, error] -> Result[Path] {
  let sha256 = pinned_url_sha256(package_name, url, checksum)?
  let root = build_source_cache_root()?
  let entry = source_cache_entry(root, sha256)

  return entry when fs.exists(entry)?

  let mirror = (e"LAPUTA_MIRROR" ?? "").trim()

  if mirror == "" {
    return Err(
      types.PmError.SourceNotFound(
        f"{package_name} source {url} (sha256 {sha256}) is not in the source cache {root}; run `make fetch`, or set LAPUTA_MIRROR to a local mirror that serves it",
      ),
    )
  }

  match fill_source_cache_entry(root, sha256, mirror_source_url(mirror, sha256))? {
    Cached => entry
    Fetched(_) => entry
    Unavailable(detail) => Err(
      types.PmError.DownloadFailed(
        f"{package_name} source {url} (sha256 {sha256}) is not in the source cache {root} or the mirror: {detail}; run `make fetch`",
      ),
    )
    Mismatch(detail) => Err(types.PmError.SourceChecksum(f"{package_name} source {url} from the mirror: {detail}"))
  }
}

pure source_selected(source: types.UpstreamSource, arch: Str) -> Bool {
  source.architectures.len() == 0 or "all" in source.architectures or arch in source.architectures
}

## Resolves one source line to a local file or directory. URL sources resolve only through the content-addressed cache or the local mirror.
export proc resolve_source(
  pkg: types.Package,
  line: types.SourceLine,
  checksum: Str,
  arch: Str,
  build: Str,
) [fs, net, env, error] -> Result[types.ResolvedSource, Error] {
  ensure_source_dest(line.dest)?
  let source = util.expand_source(line.source, pkg, arch, build)

  if source == "" {
    return Err(types.PmError.SourceName(f"{pkg.name} has an empty source"))
  }

  if util.is_url_source(source) {
    let name = util.source_basename(source)?

    return Err(types.PmError.SourceName(f"URL has no file name: {source}")) when name == ""

    return {path: resolve_url_source(pkg.name, source, checksum)?, kind: "file", name}
  }

  let source_path = fp"{source}"
  var local = source_path

  if sources_is_repository_input(source) {
    local = sources_repository_input_path(source)?
  } else if ! source.starts_with("/") {
    # Recipe-local paths are durable package inputs, including explicit parent
    # inputs such as laputa-pm's checked-in PM entrypoint.  Normalize after
    # anchoring to the typed recipe directory so no process cwd participates.
    local = fp"{pkg.dir}/{source_path}".normalize()
  }

  if ! fs.exists(local)? {
    return Err(types.PmError.SourceNotFound(f"{pkg.name} source not found: {source}"))
  }

  let metadata = fs.metadata(local)?
  {path: local, kind: metadata.kind, name: local.name}
}

# A `cargo-vendor` source names a Cargo.lock. Its crates.io records are a
# content-addressed crate set: each `checksum` is the sha256 crates.io serves
# that `.crate` under, so `make fetch` caches every crate like any pinned URL
# and a build stages them offline as a cargo directory source. Cargo.lock
# names crates.io by its git index or, with the sparse protocol, its HTTP
# index; both serve the same archives.
const crates_io_lock_sources = ["registry+https://github.com/rust-lang/crates.io-index", "sparse+https://index.crates.io/"]

# Crate names and versions become vendor directory names, so neither may
# carry a path separator.
const crate_name_pattern = rx"^[A-Za-z0-9_-]+$"
const crate_version_pattern = rx"^[0-9A-Za-z.+-]+$"

## One crates.io package a Cargo.lock pins, and the sha256 of its `.crate`.
export type LockedCrate = {name: Str, version: Str, checksum: Str}

type LockRecord = {name: Str, version: Str, source: Str, checksum: Str}

# A locked crate resolved to its verified `.crate` archive.
type ResolvedCrate = {item: LockedCrate, path: Path}

pure empty_lock_record() -> LockRecord {
  {name: "", version: "", source: "", checksum: ""}
}

# A record without `source` is a workspace or path package, built from the
# staged tree. Any other source (git, another registry) has no
# content-addressed download, so it fails here instead of reaching the
# network during a build.
pure lock_record_crates(lockfile: Path, record: LockRecord) -> Result[List[LockedCrate]] {
  return [] when record.source == ""

  let label = f"{lockfile.display()}: {record.name} {record.version}"

  if record.source not in crates_io_lock_sources {
    return Err(types.PmError.PackageContract(f"{label} comes from {record.source}; only crates.io crates can be vendored"))
  }

  if ! crate_name_pattern.matches(record.name) or ! crate_version_pattern.matches(record.version) {
    return Err(types.PmError.PackageContract(f"{label} is not a valid crate name and version"))
  }

  if ! sha256_hex.matches(record.checksum) {
    return Err(types.PmError.SourceChecksum(f"{label} has no sha256 checksum; regenerate the lockfile with current cargo"))
  }

  [{name: record.name, version: record.version, checksum: record.checksum}]
}

## Reads the crates.io packages a Cargo.lock pins, in file order. Its
## `[[package]]` records are flat `key = "value"` lines, so no TOML parser is
## needed.
export proc cargo_lock_crates(lockfile: Path) [fs, error] -> Result[List[LockedCrate], Error] {
  var crates: List[LockedCrate] = []
  var current = empty_lock_record()
  var in_package = false

  # The trailing header flushes the last record.
  for raw in lockfile.read_lines()?.push("[end]") {
    let line = raw.trim()

    if line.starts_with("[") {
      if in_package {
        crates += lock_record_crates(lockfile, current)?
      }

      in_package = line == "[[package]]"
      current = empty_lock_record()
    } else if in_package {
      if let [_, key, value] = rx"""^(name|version|source|checksum) = "([^"]*)"$""".captures(line) {
        if key == "name" {
          current = {...current, name: value}
        } else if key == "version" {
          current = {...current, version: value}
        } else if key == "source" {
          current = {...current, source: value}
        } else {
          current = {...current, checksum: value}
        }
      }
    }
  }

  crates
}

## The crates.io download of one locked crate.
export pure crate_download_url(item: LockedCrate) -> Str {
  f"https://static.crates.io/crates/{item.name}/{item.name}-{item.version}.crate"
}

# The lockfile is verified before it is trusted to name the crate set.
proc resolve_locked_crates(
  pkg: types.Package,
  resolved: types.ResolvedSource,
  checksum: Str,
) [fs, net, env, error] -> Result[List[ResolvedCrate]] {
  verify_source_checksum(resolved.path, checksum, resolved.kind)?
  var crates: List[ResolvedCrate] = []

  for item in cargo_lock_crates(resolved.path)? {
    crates += [{item, path: resolve_url_source(pkg.name, crate_download_url(item), item.checksum)?}]
  }

  crates
}

# Cargo's directory sources require `.cargo-checksum.json` beside each crate.
# Its `package` digest must match the Cargo.lock checksum, and an empty `files`
# map skips per-file verification of the already sha256-verified archive, so
# a recipe may patch a vendored crate.
proc stage_cargo_vendor(crates: List[ResolvedCrate], dest: Path) [fs, error] {
  fs.remove(dest, missing_ok: true)?
  fs.mkdir(dest)?

  for entry in crates {
    let dir = fp"{dest}/{entry.item.name}-{entry.item.version}"
    # crates.io packs every crate under one `NAME-VERSION/` directory.
    archive.tar_extract(entry.path, dir, 1, "auto", true)?
    json.write(fp"{dir}/.cargo-checksum.json", {files: {}, package: entry.item.checksum})?
  }
}

## Exported PM declaration `verify_source_checksum`.
export proc verify_source_checksum(source_path: Path, checksum: Str, kind: Str) [fs, error] {
  return when checksum == "SKIP"

  if kind == "dir" or kind == "git" {
    return Err(types.PmError.SourceChecksum(f"{source_path} must use SKIP because it is not a regular file"))
  }

  hash.verify_file(source_path, sha256: checksum)?
}

pure first_archive_path_component(path_value: Path) -> Str {
  for part in path_value.display().split("/") {
    return part when part != "" and part != "."
  }

  ""
}

## Exported PM declaration `tar_source_strip_components`.
export proc tar_source_strip_components(source_path: Path) [fs, error] -> Result[Int, Error] {
  let entries = archive.tar_list(source_path)?
  var first = ""
  var saw_entry = false

  for entry in entries {
    let component = first_archive_path_component(entry.path)

    if component != "" and component != "pax_global_header" {
      if ! saw_entry {
        first = component
        saw_entry = true
      } else if component != first {
        return 0
      }
    }
  }

  return 1 when saw_entry

  0
}

# `resolved.name` is the upstream file name: a content-addressed cache entry has
# none, and archive detection and plain-file staging both depend on it.
proc stage_resolved_source(
  line: types.SourceLine,
  resolved: types.ResolvedSource,
  source_kind: types.SourceKind,
  checksum: Str,
  crates: List[ResolvedCrate],
  src: Path,
) [fs, error] {
  let source_path = resolved.path
  let name = fp"{resolved.name}"
  verify_source_checksum(source_path, checksum, resolved.kind)?
  let dest = util.source_stage_dir(src, line)

  if source_kind == types.source_cargo_vendor() {
    stage_cargo_vendor(crates, dest)?
    return
  }

  if source_kind == types.source_directory() or resolved.kind == "dir" {
    fs.mkdir(dest)?
    let _ = fs.copy_tree(source_path, dest, parents: true, overwrite: true)?
    # Directory sources are checkout trees (recipe files or repository inputs).
    util.normalize_checkout_tree(dest)?
    return
  }

  if (source_kind == types.source_archive() and util.is_tar_source(name)) or (source_kind == types.source_auto() and util.is_tar_source(
    name,
  )) {
    fs.remove(dest, missing_ok: true)?
    dest.parent.mkdir()?
    archive.tar_extract(source_path, dest, tar_source_strip_components(source_path)?, "auto", true)?
    return
  }

  if source_kind == types.source_zip() or (source_kind == types.source_auto() and util.is_zip_source(name)) {
    fs.remove(dest, missing_ok: true)?
    dest.parent.mkdir()?
    archive.zip_extract(source_path, dest, overwrite: true)?
    return
  }

  if source_kind == types.source_cpio() or (source_kind == types.source_auto() and util.is_cpio_source(name)) {
    fs.remove(dest, missing_ok: true)?
    dest.parent.mkdir()?
    archive.cpio_extract(source_path, dest, overwrite: true)?
    return
  }

  fs.mkdir(dest)?
  fs.install(source_path, fp"{dest}/{name}", 0o644, parents: true, overwrite: true)?
}

## Resolves every source the target architecture selects, then stages them into `src`.
## Resolution finishes first, so a missing cache entry (a vendored crate's
## included) fails before any extraction.
export proc stage_package_sources(pkg: types.Package, src: Path) [fs, net, env, error] {
  let arch = util.machine_arch()?
  let build = util.build_arch()?
  var staged = []

  for source in pkg.upstream_sources {
    continue unless source_selected(source, arch)
    let line = util.parse_source_line(source.source)?
    let checksum = source_checksum(source, arch)?
    let resolved = resolve_source(pkg, line, checksum, arch, build)?
    var crates: List[ResolvedCrate] = []

    if source.kind == types.source_cargo_vendor() {
      crates = resolve_locked_crates(pkg, resolved, checksum)?
    }

    staged += [{line, resolved, kind: source.kind, checksum, crates}]
  }

  for entry in staged {
    stage_resolved_source(entry.line, entry.resolved, entry.kind, entry.checksum, entry.crates, src)?
  }
}

## Exported PM declaration `prune_git_dirs`.
export proc prune_git_dirs(src: Path) [fs, error] {
  let git_dirs = fs.walk(src, gitignore: false) |> where .kind == "dir" and .name == ".git"

  for entry in git_dirs {
    fs.remove(entry.path, missing_ok: true)?
  }
}

## Exported PM declaration `prepare_source_tree`.
export proc prepare_source_tree(pkg: types.Package, src: Path) [fs, process, env, error] {
  recipe.call_prepare_sources(pkg, src)?
}

## Stages a package's sources and runs its `prepare_sources` hook.
export proc prepare_package_source_tree(pkg: types.Package, src: Path) [fs, net, process, env, time, error] {
  let stage_started = time.now()
  print --flush "pm-build-source-start" $pkg.name "stage"
  stage_package_sources(pkg, src)?
  print --flush "pm-build-source-done" $pkg.name "stage" ${time.now() - stage_started} "ms"

  let tree_started = time.now()
  print --flush "pm-build-source-start" $pkg.name "prepare-tree"
  prepare_source_tree(pkg, src)?
  prune_git_dirs(src)?
  print --flush "pm-build-source-done" $pkg.name "prepare-tree" ${time.now() - tree_started} "ms"
}

# Checksum generation is a maintainer step that reads upstream directly: a new
# pin has no cache entry yet. The downloaded bytes enter the cache under the
# digest they produce, so the next build finds them.
proc upstream_sha256(cache_root: Path, package_name: Str, url: Str) [fs, net, error] -> Result[Str] {
  let partial_dir = fp"{cache_root}/partial"
  fs.mkdir(partial_dir)?
  let scratch = fs.tempdir()?
  defer scratch.close()?
  let download = fp"{scratch.host_path()?}/download"
  let failure = util.download_file(url, download)?

  if failure != "" {
    return Err(types.PmError.DownloadFailed(f"{package_name}: {failure}"))
  }

  let digest = hash.sha256(download)?.hex()
  let entry = source_cache_entry(cache_root, digest)

  if ! fs.exists(entry)? {
    let partial = fp"{partial_dir}/{digest}.checksum"
    fs.mkdir(entry.parent)?
    fs.copy(download, partial, overwrite: true)?
    fs.rename(partial, entry, overwrite: true)?
  }

  digest
}

## Computes the sha256 each selected source currently has upstream or on disk; `SKIP` stays `SKIP`.
export proc generate_checksums_for(
  cache_root: Path,
  pkg: types.Package,
  arch: Str,
) [fs, net, env, error] -> Result[List[Str], Error] {
  let build = util.build_arch()?
  var generated = []

  for source in pkg.upstream_sources {
    continue unless source_selected(source, arch)
    let line = util.parse_source_line(source.source)?
    let stored = source_checksum(source, arch)?
    let expanded = util.expand_source(line.source, pkg, arch, build)

    if stored == "SKIP" {
      generated += ["SKIP"]
    } else if util.is_url_source(expanded) {
      generated += [upstream_sha256(cache_root, pkg.name, expanded)?]
    } else {
      let resolved = resolve_source(pkg, line, stored, arch, build)?

      if resolved.kind == "dir" {
        generated += ["SKIP"]
      } else {
        generated += [hash.sha256(resolved.path)?.hex()]
      }
    }
  }

  generated
}

## Exported PM declaration `collect_checksum_updates`.
export proc collect_checksum_updates(
  cache_root: Path,
  pkg: types.Package,
) [fs, net, env, error] -> Result[List[types.ChecksumUpdate], Error] {
  let arch = util.machine_arch()?
  let generated = generate_checksums_for(cache_root, pkg, arch)?
  [{field: f"upstream_sources:{arch}", values: generated}]
}

## Exported PM declaration `write_checksum_field`.
export proc write_checksum_field(pkg: types.Package, field: Str, values: List[Str]) [fs, error] {
  let field_parts = field.split(":")

  if field_parts.len() != 2 or field_parts[0] != "upstream_sources" {
    return Err(types.PmError.ChecksumField(f"unsupported checksum field {field}"))
  }

  let arch = field_parts[1]
  let pkgbuild = fp"{pkg.dir}/PKGBUILD.xsh"
  let body = fs.read_text(pkgbuild)?
  let lines = body.split("\n")
  let has_arch_specific = f"arch: \"{arch}\"" in body
  var output = []
  var in_sources = false
  var found = false
  var value_index = 0

  for line in lines {
    let trimmed = line.trim()

    if ! in_sources and trimmed.starts_with("export let upstream_sources = [") {
      in_sources = true
      output += [line]
      continue
    }

    if in_sources {
      if trimmed == "]" {
        in_sources = false
      } else if (f"arch: \"{arch}\"" in line or (! has_arch_specific and "arch: \"all\"" in line)) and "sha256: \"" in line {
        if value_index >= values.len() {
          return Err(
            types.PmError.ChecksumField(f"{pkgbuild} has fewer {arch} checksum entries than expected"),
          )
        }

        let marker = "sha256: \""
        let parts = line.split(marker)
        let old = (parts.get(1) ?? "").split("\"").get(0) ?? ""
        let value = values.get(value_index)?
        output += [line.replace(f"{old}\"", f"{value}\"")]
        value_index += 1
        found = true
        continue
      }
    }

    output += [line]
  }

  if ! found or value_index != values.len() {
    return Err(types.PmError.ChecksumField(f"{pkgbuild} has no complete {arch} checksum field"))
  }

  fs.write_atomic(pkgbuild, output.join("\n"))?
}

## One pinned upstream download: every package and URL that names the same content.
export type SourceFetchItem = {sha256: Str, urls: List[Str], packages: List[Str]}

## Collects the pinned URL sources `packages` select for `arch`, one item per
## sha256. Builds run natively, so the build architecture equals the target.
export proc source_fetch_items(packages: List[types.Package], arch: Str) [error] -> Result[List[SourceFetchItem], Error] {
  var by_sha256: Map[SourceFetchItem] = {}

  for pkg in packages {
    for source in pkg.upstream_sources {
      continue unless source_selected(source, arch)
      let line = util.parse_source_line(source.source)?
      let url = util.expand_source(line.source, pkg, arch, arch)
      continue unless util.is_url_source(url)
      let sha256 = pinned_url_sha256(pkg.name, url, source_checksum(source, arch)?)?
      by_sha256 = with_fetch_item(by_sha256, sha256, url, pkg.name)
    }
  }

  sorted_fetch_items(by_sha256)
}

pure with_fetch_item(by_sha256: Map[SourceFetchItem], sha256: Str, url: Str, package_name: Str) -> Map[SourceFetchItem] {
  let empty: List[Str] = []
  let existing = by_sha256.get(sha256) ?? {sha256, urls: empty, packages: empty}
  var updated = by_sha256
  updated[sha256] = {
    sha256,
    urls: if url in existing.urls { existing.urls } else { existing.urls.push(url) },
    packages: if package_name in existing.packages { existing.packages } else { existing.packages.push(package_name) },
  }
  updated
}

pure sorted_fetch_items(by_sha256: Map[SourceFetchItem]) -> List[SourceFetchItem] {
  by_sha256.values() |> sort-by { |item| f"{item.packages[0]}\t{item.urls[0]}" }
}

## Collects the `.crate` downloads the `cargo-vendor` sources of `packages`
## pin for `arch`, one item per sha256. A URL lockfile is read from the cache
## at `root`, so `fetch_sources` must have cached the lockfiles first.
export proc cargo_crate_fetch_items(
  root: Path,
  packages: List[types.Package],
  arch: Str,
) [fs, net, env, error] -> Result[List[SourceFetchItem], Error] {
  var by_sha256: Map[SourceFetchItem] = {}

  for pkg in packages {
    for source in pkg.upstream_sources {
      continue unless source_selected(source, arch) and source.kind == types.source_cargo_vendor()
      let line = util.parse_source_line(source.source)?
      let expanded = util.expand_source(line.source, pkg, arch, arch)
      let checksum = source_checksum(source, arch)?
      var lockfile = p""

      if util.is_url_source(expanded) {
        lockfile = source_cache_entry(root, pinned_url_sha256(pkg.name, expanded, checksum)?)

        guard fs.exists(lockfile)? else {
          return Err(types.PmError.SourceNotFound(f"{pkg.name} lockfile {expanded} is not in the source cache {root}"))
        }
      } else {
        let resolved = resolve_source(pkg, line, checksum, arch, arch)?
        verify_source_checksum(resolved.path, checksum, resolved.kind)?
        lockfile = resolved.path
      }

      for item in cargo_lock_crates(lockfile)? {
        by_sha256 = with_fetch_item(by_sha256, item.checksum, crate_download_url(item), pkg.name)
      }
    }
  }

  sorted_fetch_items(by_sha256)
}

# A dead host or a transient failure gets a few spaced retries. A checksum
# mismatch or a missing `file://` path is deterministic, so neither is retried.
proc fetch_source_item(root: Path, item: SourceFetchItem) [fs, net, time, error] -> Result[SourceFetchOutcome] {
  return Cached when fs.exists(source_cache_entry(root, item.sha256))?

  var unavailable: List[Str] = []
  var mismatched: List[Str] = []

  for url in item.urls {
    var last_failure = ""

    let delays = if util.is_file_url(url) { [0s] } else { [0s, 2s, 5s, 15s] }

    for delay in delays {
      if delay > 0s {
        time.sleep(delay)?
      }

      let outcome = fill_source_cache_entry(root, item.sha256, url)?

      match outcome {
        Unavailable(detail) => last_failure = detail
        Mismatch(detail) => {
          mismatched += [detail]
          last_failure = ""
          break
        }
        _ => return outcome
      }
    }

    if last_failure != "" {
      unavailable += [last_failure]
    }
  }

  return Mismatch(mismatched.extend(unavailable).join("; ")) when mismatched.len() > 0

  Unavailable(unavailable.join("; "))
}

pure source_fetch_label(item: SourceFetchItem) -> Str {
  f"{item.packages.join(",")} {item.urls[0]}"
}

## Downloads every item missing from the cache with at most four transfers in
## flight, verifies each sha256, and reports every dead URL and checksum
## mismatch together before failing.
export proc fetch_sources(root: Path, items: List[SourceFetchItem]) [fs, net, time, error] {
  fs.mkdir(fp"{root}/sha256")?

  # par-map workers do not forward stdout, so progress goes to flushed stderr.
  let results = items |> par-map(jobs: 4) { |item|
    let outcome = fetch_source_item(root, item)?
    let label = source_fetch_label(item)

    match outcome {
      Cached => eprint --flush "sources" "cached" $label
      Fetched(size) => eprint --flush "sources" "fetched" $size $label
      Unavailable(_) => eprint --flush "sources" "dead" $label
      Mismatch(_) => eprint --flush "sources" "mismatch" $label
    }

    {item, outcome}
  }

  var cached = 0
  var fetched = 0
  var fetched_bytes = 0
  var failures: List[Str] = []

  for result in results {
    match result.outcome {
      Cached => cached += 1
      Fetched(size) => {
        fetched += 1
        fetched_bytes += size
      }
      Unavailable(detail) => failures += [f"dead {result.item.packages.join(",")}: {detail}"]
      Mismatch(detail) => failures += [f"mismatch {result.item.packages.join(",")}: {detail}"]
    }
  }

  print "sources" "summary" $cached "cached" $fetched "fetched" $fetched_bytes "bytes" failures.len() "failed" "cache" $root

  for failure in failures {
    eprint $failure
  }

  if failures.len() > 0 {
    return Err(types.PmError.DownloadFailed(f"{failures.len()} pinned source(s) could not be fetched"))
  }
}
