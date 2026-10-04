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
  let root = (env.get("XSH_PM_REPOSITORY_ROOT") ?? "").trim()
  let relative = fp"${source.replace("repository/", "")}".normalize()

  if root == "" {
    return Err(types.PmError.PackageContract(f"repository source ${source} needs XSH_PM_REPOSITORY_ROOT"))
  }

  let _ = util.ensure_relative_path(relative, f"repository source ${source}")?
  fp"${root}/${relative}"
}

## Exported PM declaration `ensure_source_dest`.
export pure ensure_source_dest(dest: Path) -> Result[Unit] {
  let _ = util.ensure_relative_path(dest, "source destination")?
}

## Exported PM declaration `source_checksum`.
export proc source_checksum(source: types.UpstreamSource, arch: Str) [error] -> Result[Str] {
  for checksum in source.checksums {
    if checksum.arch == arch or checksum.arch == "all" {
      return checksum.sha256
    }
  }

  Err(types.PmError.SourceChecksum(f"no checksum for ${source.source} on ${arch}"))
}

# URL sources are content-addressed: `make fetch` (`pm sources fetch`) is the
# only step that contacts upstream hosts. Builds resolve a pinned URL source from
# the cache, then from the local mirror named by LAPUTA_MIRROR, and otherwise
# fail. The source string and checksum stay the recipe's identity, so where the
# bytes come from never changes a fingerprint.
const sha256_hex = rx"^[0-9a-f]{64}$"

## The source cache root for a package repository: LAPUTA_SOURCE_CACHE when set,
## otherwise `.cache/sources` under the repository root.
export proc source_cache_root(repo_root: Path) [fs, env, error] -> Result[Path] {
  let configured = (env.get("LAPUTA_SOURCE_CACHE") ?? "").trim()

  if configured != "" {
    return path.absolute(fp"${configured}")?
  }

  fp"${repo_root}/.cache/sources"
}

# Builds name their package repository through XSH_PM_REPOSITORY_ROOT, the same
# root that `repository/` inputs resolve against.
proc build_source_cache_root() [fs, env, error] -> Result[Path] {
  let configured = (env.get("LAPUTA_SOURCE_CACHE") ?? "").trim()
  let repo_root = (env.get("XSH_PM_REPOSITORY_ROOT") ?? "").trim()

  if configured == "" and repo_root == "" {
    return Err(types.PmError.SourceNotFound("URL sources need LAPUTA_SOURCE_CACHE or XSH_PM_REPOSITORY_ROOT to locate the source cache"))
  }

  source_cache_root(fp"${repo_root}")?
}

## The cache entry for one sha256, the layout the local mirror serves at `/sources/sha256/<hash>`.
export pure source_cache_entry(root: Path, sha256: Str) -> Path {
  fp"${root}/sha256/${sha256}"
}

## The local mirror URL for one cached source.
export pure mirror_source_url(mirror: Str, sha256: Str) -> Str {
  var base = mirror.trim()

  while base.ends_with("/") {
    base = base.byte_slice(0, base.byte_len() - 1)
  }

  f"${base}/sources/sha256/${sha256}"
}

## Validates the pin a URL source is cached under. `SKIP` is only for repository-local sources.
export pure pinned_url_sha256(package_name: Str, url: Str, checksum: Str) -> Result[Str] {
  if checksum == "SKIP" {
    return Err(types.PmError.SourceChecksum(f"${package_name} URL source ${url} must pin a sha256; SKIP is only for repository-local sources"))
  }

  if ! sha256_hex.matches(checksum) {
    return Err(types.PmError.SourceChecksum(f"${package_name} URL source ${url} has a malformed sha256 ${checksum}"))
  }

  checksum
}

## How filling one source cache entry ended.
export enum SourceFetchOutcome { Cached, Fetched(Int), Unavailable(Str), Mismatch(Str) }

## Downloads `url` into the cache entry for `sha256`, publishing only verified bytes.
export proc fill_source_cache_entry(root: Path, sha256: Str, url: Str) [fs, net, error] -> Result[SourceFetchOutcome] {
  let entry = source_cache_entry(root, sha256)
  let partial_dir = fp"${root}/partial"
  fs.mkdir(entry.parent)?
  fs.mkdir(partial_dir)?
  # Packages built in parallel can share one source, so one writer fills an entry.
  let lock = fs.lock(fp"${partial_dir}/${sha256}.lock")?
  defer fs.unlock(lock)?

  if fs.exists(entry)? {
    return Cached
  }

  let partial = fp"${partial_dir}/${sha256}"
  fs.remove(partial, missing_ok: true)?
  defer fs.remove(partial, missing_ok: true)?
  let failure = util.download_file(url, partial)?

  if failure != "" {
    return Unavailable(failure)
  }

  let actual = hash.sha256(partial)?.hex()

  if actual != sha256 {
    return Mismatch(f"${url}: expected sha256 ${sha256}, got ${actual}")
  }

  let size = fs.metadata(partial)?.size
  fs.rename(partial, entry)?
  Fetched(size)
}

proc resolve_url_source(package_name: Str, url: Str, checksum: Str) [fs, net, env, error] -> Result[Path] {
  let sha256 = pinned_url_sha256(package_name, url, checksum)?
  let root = build_source_cache_root()?
  let entry = source_cache_entry(root, sha256)

  if fs.exists(entry)? {
    return entry
  }

  let mirror = (env.get("LAPUTA_MIRROR") ?? "").trim()

  if mirror == "" {
    return Err(
      types.PmError.SourceNotFound(f"${package_name} source ${url} (sha256 ${sha256}) is not in the source cache ${root}; run `make fetch`, or set LAPUTA_MIRROR to a local mirror that serves it"),
    )
  }

  match fill_source_cache_entry(root, sha256, mirror_source_url(mirror, sha256))? {
    Cached => entry
    Fetched(_) => entry
    Unavailable(detail) => Err(types.PmError.DownloadFailed(f"${package_name} source ${url} (sha256 ${sha256}) is not in the source cache ${root} or the mirror: ${detail}; run `make fetch`"))
    Mismatch(detail) => Err(types.PmError.SourceChecksum(f"${package_name} source ${url} from the mirror: ${detail}"))
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
) [fs, net, env, error] -> Result[types.ResolvedSource] {
  ensure_source_dest(line.dest)?
  let source = util.expand_source(line.source, pkg, arch, build)

  if source == "" {
    return Err(types.PmError.SourceName(f"${pkg.name} has an empty source"))
  }

  if util.is_url_source(source) {
    let name = util.source_basename(source)?

    if name == "" {
      return Err(types.PmError.SourceName(f"URL has no file name: ${source}"))
    }

    return {path: resolve_url_source(pkg.name, source, checksum)?, kind: "file", name}
  }

  let source_path = fp"${source}"
  var local = source_path

  if sources_is_repository_input(source) {
    local = sources_repository_input_path(source)?
  } else if ! source.starts_with("/") {
    # Recipe-local paths are durable package inputs, including explicit parent
    # inputs such as laputa-pm's checked-in PM entrypoint.  Normalize after
    # anchoring to the typed recipe directory so no process cwd participates.
    local = fp"${pkg.dir}/${source_path}".normalize()
  }

  if ! fs.exists(local)? {
    return Err(types.PmError.SourceNotFound(f"${pkg.name} source not found: ${source}"))
  }

  let metadata = fs.metadata(local)?
  {path: local, kind: metadata.kind, name: local.name}
}

## Exported PM declaration `verify_source_checksum`.
export proc verify_source_checksum(source_path: Path, checksum: Str, kind: Str) [fs, error] {
  if checksum == "SKIP" {
    return
  }

  if kind == "dir" or kind == "git" {
    return Err(types.PmError.SourceChecksum(f"${source_path} must use SKIP because it is not a regular file"))
  }

  hash.verify_file(source_path, sha256: checksum)?
}

pure first_archive_path_component(path_value: Path) -> Str {
  for part in path_value.display().split("/") {
    if part != "" and part != "." {
      return part
    }
  }

  ""
}

## Exported PM declaration `tar_source_strip_components`.
export proc tar_source_strip_components(source_path: Path) [fs, error] -> Result[Int] {
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

  if saw_entry {
    return 1
  }

  0
}

# `resolved.name` is the upstream file name: a content-addressed cache entry has
# none, and archive detection and plain-file staging both depend on it.
proc stage_resolved_source(
  line: types.SourceLine,
  resolved: types.ResolvedSource,
  source_kind: types.SourceKind,
  checksum: Str,
  src: Path,
) [fs, error] {
  let source_path = resolved.path
  let name = fp"${resolved.name}"
  verify_source_checksum(source_path, checksum, resolved.kind)?
  let dest = util.source_stage_dir(src, line)

  if source_kind == types.source_directory() or resolved.kind == "dir" {
    fs.mkdir(dest)?
    fs.copy_tree(source_path, dest, parents: true, overwrite: true)?
    return
  }

  if (source_kind == types.source_archive() and util.is_tar_source(name)) or (source_kind == types.source_auto() and util.is_tar_source(name)) {
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
  fs.install(source_path, fp"${dest}/${name}", 0o644, parents: true, overwrite: true)?
}

## Resolves every source the target architecture selects, then stages them into `src`.
## Resolution finishes first, so a missing cache entry fails before any extraction.
export proc stage_package_sources(pkg: types.Package, src: Path) [fs, net, env, error] {
  let arch = util.machine_arch()?
  let build = util.build_arch()?
  var staged = []

  for source in pkg.upstream_sources {
    continue unless source_selected(source, arch)
    let line = util.parse_source_line(source.source)?
    let checksum = source_checksum(source, arch)?
    let resolved = resolve_source(pkg, line, checksum, arch, build)?
    staged = staged.push({line, resolved, kind: source.kind, checksum})
  }

  for entry in staged {
    stage_resolved_source(entry.line, entry.resolved, entry.kind, entry.checksum, src)?
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
## Temporary: the executor and the LLVM seed script still pass the retired
## work, out, force-download, and source-mirror arguments, which are ignored;
## drop them here together with those two call sites.
export proc prepare_package_source_tree(
  _work: Path,
  _out: Path,
  pkg: types.Package,
  src: Path,
  _force_download: Bool,
  _allow_mirror: Bool,
  _pack_mirror: Bool,
) [fs, net, process, env, time, error] {
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
  let partial_dir = fp"${cache_root}/partial"
  fs.mkdir(partial_dir)?
  let download = fs.tempfile()?
  defer download.root.close()?
  let failure = util.download_file(url, download.path)?

  if failure != "" {
    return Err(types.PmError.DownloadFailed(f"${package_name}: ${failure}"))
  }

  let digest = hash.sha256(download.path)?.hex()
  let entry = source_cache_entry(cache_root, digest)

  if ! fs.exists(entry)? {
    let partial = fp"${partial_dir}/${digest}.checksum"
    fs.mkdir(entry.parent)?
    fs.copy(download.path, partial, overwrite: true)?
    fs.rename(partial, entry, overwrite: true)?
  }

  digest
}

## Computes the sha256 each selected source currently has upstream or on disk; `SKIP` stays `SKIP`.
export proc generate_checksums_for(
  cache_root: Path,
  pkg: types.Package,
  arch: Str,
) [fs, net, env, error] -> Result[List[Str]] {
  let build = util.build_arch()?
  var generated = []

  for source in pkg.upstream_sources {
    continue unless source_selected(source, arch)
    let line = util.parse_source_line(source.source)?
    let stored = source_checksum(source, arch)?
    let expanded = util.expand_source(line.source, pkg, arch, build)

    if stored == "SKIP" {
      generated = generated.push("SKIP")
    } else if util.is_url_source(expanded) {
      generated = generated.push(upstream_sha256(cache_root, pkg.name, expanded)?)
    } else {
      let resolved = resolve_source(pkg, line, stored, arch, build)?

      if resolved.kind == "dir" {
        generated = generated.push("SKIP")
      } else {
        generated = generated.push(hash.sha256(resolved.path)?.hex())
      }
    }
  }

  generated
}

## Exported PM declaration `collect_checksum_updates`.
export proc collect_checksum_updates(
  cache_root: Path,
  pkg: types.Package,
) [fs, net, env, error] -> Result[List[types.ChecksumUpdate]] {
  let arch = util.machine_arch()?
  let generated = generate_checksums_for(cache_root, pkg, arch)?
  [{field: f"upstream_sources:${arch}", values: generated}]
}

## Exported PM declaration `write_checksum_field`.
export proc write_checksum_field(pkg: types.Package, field: Str, values: List[Str]) [fs, error] {
  let field_parts = field.split(":")

  if field_parts.len() != 2 or field_parts[0] != "upstream_sources" {
    return Err(types.PmError.ChecksumField(f"unsupported checksum field ${field}"))
  }

  let arch = field_parts[1]
  let pkgbuild = fp"${pkg.dir}/PKGBUILD.xsh"
  let body = fs.read_text(pkgbuild)?
  let lines = body.split("\n")
  let has_arch_specific = f"arch: \"${arch}\"" in body
  var output = []
  var in_sources = false
  var found = false
  var value_index = 0

  for line in lines {
    let trimmed = line.trim()

    if ! in_sources and trimmed.starts_with("export let upstream_sources = [") {
      in_sources = true
      output = output.push(line)
      continue
    }

    if in_sources {
      if trimmed == "]" {
        in_sources = false
      } else if (f"arch: \"${arch}\"" in line or (! has_arch_specific and "arch: \"all\"" in line)) and "sha256: \"" in line {
        if value_index >= values.len() {
          return Err(
            types.PmError.ChecksumField(f"${pkgbuild} has fewer ${arch} checksum entries than expected"),
          )
        }

        let marker = "sha256: \""
        let parts = line.split(marker)
        let old = (parts.get(1) ?? "").split("\"").get(0) ?? ""
        let value = values.get(value_index)?
        output = output.push(line.replace(f"${old}\"", f"${value}\""))
        value_index += 1
        found = true
        continue
      }
    }

    output = output.push(line)
  }

  if ! found or value_index != values.len() {
    return Err(types.PmError.ChecksumField(f"${pkgbuild} has no complete ${arch} checksum field"))
  }

  fs.write_atomic(pkgbuild, output.join("\n"))?
}

## One pinned upstream download: every package and URL that names the same content.
export type SourceFetchItem = {sha256: Str, urls: List[Str], packages: List[Str]}

## Collects the pinned URL sources `packages` select for `arch`, one item per
## sha256. Builds run natively, so the build architecture equals the target.
export proc source_fetch_items(packages: List[types.Package], arch: Str) [error] -> Result[List[SourceFetchItem]] {
  var by_sha256: Map[SourceFetchItem] = {}

  for pkg in packages {
    for source in pkg.upstream_sources {
      continue unless source_selected(source, arch)
      let line = util.parse_source_line(source.source)?
      let url = util.expand_source(line.source, pkg, arch, arch)
      continue unless util.is_url_source(url)
      let sha256 = pinned_url_sha256(pkg.name, url, source_checksum(source, arch)?)?
      let empty: List[Str] = []
      let existing = by_sha256.get(sha256) ?? {sha256, urls: empty, packages: empty}
      by_sha256[sha256] = {
        sha256,
        urls: if url in existing.urls { existing.urls } else { existing.urls.push(url) },
        packages: if pkg.name in existing.packages { existing.packages } else { existing.packages.push(pkg.name) },
      }
    }
  }

  by_sha256.values() |> sort-by { |item| f"${item.packages[0]}\t${item.urls[0]}" }
}

# A dead host or a transient failure gets a few spaced retries. A checksum
# mismatch or a missing `file://` path is deterministic, so neither is retried.
proc fetch_source_item(root: Path, item: SourceFetchItem) [fs, net, time, error] -> Result[SourceFetchOutcome] {
  if fs.exists(source_cache_entry(root, item.sha256))? {
    return Cached
  }

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
          mismatched = mismatched.push(detail)
          last_failure = ""
          break
        }
        _ => return outcome
      }
    }

    if last_failure != "" {
      unavailable = unavailable.push(last_failure)
    }
  }

  if mismatched.len() > 0 {
    return Mismatch(mismatched.extend(unavailable).join("; "))
  }

  Unavailable(unavailable.join("; "))
}

pure source_fetch_label(item: SourceFetchItem) -> Str {
  f"${item.packages.join(",")} ${item.urls[0]}"
}

## Downloads every item missing from the cache with at most four transfers in
## flight, verifies each sha256, and reports every dead URL and checksum
## mismatch together before failing.
export proc fetch_sources(root: Path, items: List[SourceFetchItem]) [fs, net, time, error] {
  fs.mkdir(fp"${root}/sha256")?

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
      Unavailable(detail) => failures = failures.push(f"dead ${result.item.packages.join(",")}: ${detail}")
      Mismatch(detail) => failures = failures.push(f"mismatch ${result.item.packages.join(",")}: ${detail}")
    }
  }

  print "sources" "summary" $cached "cached" $fetched "fetched" $fetched_bytes "bytes" ${failures.len()} "failed" "cache" $root

  for failure in failures {
    eprint $failure
  }

  if failures.len() > 0 {
    return Err(types.PmError.DownloadFailed(f"${failures.len()} pinned source(s) could not be fetched"))
  }
}
