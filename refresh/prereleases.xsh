##! Refresh GitHub release pins in recipes from the newest published prerelease.
use pm.catalog
use pm.recipe
use pm.types
use pm.util as pm_util

const RELEASE_URL = rx"""^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/releases/download/([^/"]+)/"""
const ENTRY_UPDATED = rx"<updated>([^<]+)</updated>"
const ENTRY_TAG = rx"""releases/tag/([^"']+)["']"""
const SUMS_LINE = rx"""^([0-9a-f]{64})\s+\*?(\S+)$"""
const REL_LINE = rx"""^export (const|let) rel = "([0-9]+)"$"""
const COMMIT_TAG = rx"^release-([0-9a-f]{40})$"
const ARCHIVE_SUFFIXES = [".tar.gz", ".tar.xz", ".tar.zst", ".tar.bz2", ".tar.lzma", ".tbz2", ".txz", ".tgz", ".tar", ".zip", ".gz", ".xz"]

## One pinned GitHub release URL in a recipe.
export type Pin = {spec: Str, url: Str, owner: Str, repository: Str, tag: Str}
type FeedEntry = {updated: Str, tag: Str}
type ChecksumChange = {arch: Str, old: Str, new: Str}
type ResolvedAsset = {name: Str, sha256: Str}
type Edit = {old: Str, new: Str}
## The before/after recipe text and metadata for one refresh.
export type RefreshPlan = {
  name: Str,
  path: Path,
  before: Str,
  after: Str,
  old_tag: Str,
  new_tag: Str,
  old_rel: Str,
  new_rel: Str,
  checksums: List[ChecksumChange],
  warning: Str,
}

type FormatTokens = {ext: Str, compression: Str}
type Span = {start: Int, len: Int, value: Str}

pure spans_overlap(spans: List[Span], start: Int, len: Int) -> Bool {
  for span in spans {
    return true when start < span.start + span.len and span.start < start + len
  }
  false
}

pure add_span(text: Str, spans: List[Span], needle: Str, replacement: Str) -> List[Span] {
  guard needle != "" and needle != replacement else { return spans }
  var result = spans
  var from = 0
  while true {
    let at = text.find(needle, from) ?? -1
    guard at >= 0 else { return result }
    if ! spans_overlap(result, at, needle.byte_len()) {
      result += [{start: at, len: needle.byte_len(), value: replacement}]
    }
    from = at + needle.byte_len()
  }
}

pure apply_spans(text: Str, spans: List[Span]) -> Str {
  var out = text
  for span in spans |> sort-by(desc: true) .start {
    out = out.byte_slice(0, span.start) + span.value + out.byte_slice(span.start + span.len)
  }
  out
}

## Extract the release repository and tag from one recipe source string.
export pure parse_pin_text(text: Str) -> Result[Pin, Error] {
  let url = text.split(" => ")[0]
  let parts = RELEASE_URL.captures(url)
  guard parts.len() == 4 else {
    return Err(types.PmError.PackageContract(f"not a GitHub release source: {url}"))
  }
  Ok({spec: text, url, owner: parts[1], repository: parts[2], tag: parts[3]})
}

## Return the one GitHub release pin a recipe must declare.
export pure current_pin(pkg: types.Package) -> Result[Pin, Error] {
  let pins: List[Pin] = collect {
    for source in pkg.upstream_sources {
      if let Ok(pin) = parse_pin_text(source.source.display()) { yield pin }
    }
  }
  guard ! pins.is_empty() else {
    return Err(types.PmError.PackageContract(f"{pkg.name}: no GitHub release source to refresh"))
  }
  for pin in pins {
    guard pin.owner == pins[0].owner and pin.repository == pins[0].repository and pin.tag == pins[0].tag else {
      return Err(types.PmError.PackageContract(f"{pkg.name}: release sources disagree on repository or tag"))
    }
  }
  Ok(pins[0])
}

## Parse release entries from a GitHub releases.atom feed, newest first.
export pure feed_entries(body: Str, prefix: Str) -> List[FeedEntry] {
  let chunks = body.split("<entry>")
  var index = 1
  let found: List[FeedEntry] = collect {
    while index < chunks.len() {
      let entry = chunks[index].split("</entry>")[0]
      let updated = ENTRY_UPDATED.captures(entry)
      let tagged = ENTRY_TAG.captures(entry)
      if updated.len() == 2 and tagged.len() == 2 and tagged[1].starts_with(prefix) {
        yield {updated: updated[1], tag: tagged[1]}
      }
      index += 1
    }
  }
  found |> sort-by(desc: true) .updated
}

## Select the newest prerelease tag from a parsed feed body.
export pure latest_tag(body: Str, prefix: Str) -> Str {
  let entries = feed_entries(body, prefix)
  if entries.is_empty() { "" } else { entries[0].tag }
}

## Index an upstream SHA256SUMS body by asset name.
export pure sums_map(body: Str) -> Map[Str, Str] {
  var result: Map[Str, Str] = {}
  for line in body.split("\n") {
    let parts = SUMS_LINE.captures(line.trim())
    if parts.len() == 3 { result[parts[2]] = parts[1] }
  }
  result
}

## Return the full commit a release-<sha> tag pins, or an empty string.
export pure commit_sha(tag: Str) -> Str {
  let parts = COMMIT_TAG.captures(tag)
  if parts.len() == 2 { parts[1] } else { "" }
}

## Return the archive suffix that decides an asset's wire format.
export pure archive_ext(name: Str) -> Str {
  for suffix in ARCHIVE_SUFFIXES {
    return suffix when name.ends_with(suffix)
  }
  ""
}

## Strip the archive suffix so an asset can be matched across a format change.
export pure asset_stem(name: Str) -> Str {
  let ext = archive_ext(name)
  if ext == "" { name } else { name.byte_slice(0, name.byte_len() - ext.byte_len()) }
}

## Find an asset in a release's sums, allowing only an archive-format change.
export pure resolve_asset(old_asset: Str, sums: Map[Str, Str]) -> Result[ResolvedAsset, Error] {
  let direct = sums.get(old_asset) ?? ""
  return Ok({name: old_asset, sha256: direct}) when direct.byte_len() == 64
  let stem = asset_stem(old_asset)
  let matches = [name for name in sums.keys() if asset_stem(name) == stem]
  guard matches.len() == 1 else {
    return Err(types.PmError.SourceChecksum(f"expected one asset with stem {stem}, found {matches.len()}"))
  }
  Ok({name: matches[0], sha256: sums.get(matches[0]) ?? ""})
}

## Map an archive suffix to the XSH build tokens that name its format.
export pure format_tokens(ext: Str) -> FormatTokens {
  if ext == ".tar.gz" or ext == ".tgz" or ext == ".gz" { return {ext: "gz", compression: ".Gzip"} }
  if ext == ".tar.xz" or ext == ".txz" or ext == ".xz" { return {ext: "xz", compression: ".Xz"} }
  return {ext: "zst", compression: ".Zstd"} when ext == ".tar.zst" or ext == ".zst"
  return {ext: "bz2", compression: ".Bzip2"} when ext == ".tar.bz2" or ext == ".tbz2"
  {ext: "", compression: ""}
}

## Fetch a public upstream text document with a bounded body.
export proc fetch_text(url: Str) [net, error] -> Result[Str, Error] {
  let response = net.request({
    method: "GET",
    url,
    headers: [{name: "Accept", value: "*/*"}, {name: "User-Agent", value: "laputa-refresh-prereleases"}],
    timeout: 15s,
    connect_timeout: 5s,
    max_body_bytes: 1048576,
  }).context("refresh-prereleases", url)?
  guard response.status == 200 else {
    return Err(types.PmError.RemoteFetch(f"{url}: HTTP {response.status}"))
  }
  Ok(response.body as Str)
}

## Build the exact recipe text edits for moving one pin to a new release.
export proc build_refresh(pkg: types.Package, pin: Pin, new_tag: Str, sums: Map[Str, Str]) [fs, env, error] -> Result[RefreshPlan, Error] {
  let pkgbuild = fp"{pkg.dir}/PKGBUILD.xsh"
  let before = pkgbuild.read_text()?
  let build = pm_util.build_arch()?
  var edits: List[Edit] = []
  var checksum_changes: List[ChecksumChange] = []
  var old_ext = ""
  var new_ext = ""

  for source in pkg.upstream_sources {
    if let Ok(found) = parse_pin_text(source.source.display()) {
      for checksum in source.checksums {
        continue unless checksum.sha256 != "SKIP"
        let expanded = pm_util.expand_source(found.url, pkg, checksum.arch, build)
        let asset = pm_util.source_basename(expanded)?
        let resolved = resolve_asset(asset, sums)?
        guard resolved.sha256.byte_len() == 64 else {
          return Err(types.PmError.SourceChecksum(f"{pkg.name}: {new_tag} has no checksum for {asset}"))
        }
        let from_ext = archive_ext(asset)
        let to_ext = archive_ext(resolved.name)
        guard (old_ext == "" or old_ext == from_ext) and (new_ext == "" or new_ext == to_ext) else {
          return Err(types.PmError.PackageContract(f"{pkg.name}: release sources disagree on archive format"))
        }
        if old_ext == "" { old_ext = from_ext }
        if new_ext == "" { new_ext = to_ext }
        edits += [{old: checksum.sha256, new: resolved.sha256}]
        checksum_changes += [{arch: checksum.arch, old: checksum.sha256, new: resolved.sha256}]
      }
      var new_url = found.url.replace(found.tag, with: new_tag)
      if old_ext != "" and old_ext != new_ext {
        new_url = new_url.replace(old_ext, with: new_ext)
      }
      edits += [{old: found.url, new: new_url}]
    }
  }

  guard ! checksum_changes.is_empty() else {
    return Err(types.PmError.PackageContract(f"{pkg.name}: release sources have no per-arch checksums"))
  }

  var warning = ""
  if old_ext != "" and new_ext != "" and old_ext != new_ext {
    let from = format_tokens(old_ext)
    let to = format_tokens(new_ext)
    if from.ext != "" and to.ext != "" {
      let from_ext_token = f".ext == \"{from.ext}\""
      let from_compression = f"compression: {from.compression}"
      if from_ext_token in before {
        edits += [{old: from_ext_token, new: f".ext == \"{to.ext}\""}]
      }
      if from_compression in before {
        edits += [{old: from_compression, new: f"compression: {to.compression}"}]
      }
    }
    if from.ext == "" or to.ext == "" or (f".ext == \"{from.ext}\"" not in before and f"compression: {from.compression}" not in before) {
      warning = f"archive format changed from {old_ext} to {new_ext}: review the build hook"
    }
  }

  var rel_old = ""
  var rel_new = ""
  var new_rel = ""
  for line in before.split("\n") {
    let parts = REL_LINE.captures(line)
    if parts.len() == 3 and parts[2] == pkg.rel {
      let bumped = parts[2] as Int + 1
      rel_old = line
      rel_new = f"export {parts[1]} rel = \"{bumped}\""
      new_rel = f"{bumped}"
    }
  }
  guard rel_old != "" else {
    return Err(types.PmError.PackageContract(f"{pkg.name}: could not find the rel declaration"))
  }
  edits += [{old: rel_old, new: rel_new}]

  let old_commit = commit_sha(pin.tag)
  let new_commit = commit_sha(new_tag)
  var comment_edits: List[Edit] = []
  for line in before.split("\n") {
    continue unless line.trim().starts_with("##")
    var spans: List[Span] = []
    spans = add_span(line, spans, pin.tag, new_tag)
    if old_commit.byte_len() >= 7 and new_commit.byte_len() >= 7 and old_commit != new_commit {
      var length = 12
      while length >= 7 {
        let previous = spans.len()
        spans = add_span(line, spans, old_commit.byte_slice(0, length), new_commit.byte_slice(0, length))
        break when spans.len() > previous
        length -= 1
      }
    }
    for change in checksum_changes {
      if change.old != change.new {
        spans = add_span(line, spans, change.old.byte_slice(0, 8), change.new.byte_slice(0, 8))
      }
    }
    let updated = apply_spans(line, spans)
    if updated != line { comment_edits += [{old: line, new: updated}] }
  }

  var after = before
  for edit in edits + comment_edits {
    guard edit.old != edit.new else { continue }
    guard edit.old in after else {
      return Err(types.PmError.PackageContract(f"{pkg.name}: expected text is missing: {edit.old}"))
    }
    after = after.replace(edit.old, with: edit.new)
  }
  guard after != before else {
    return Err(types.PmError.PackageContract(f"{pkg.name}: refresh produced no changes"))
  }

  Ok({
    name: pkg.name, path: pkgbuild, before, after,
    old_tag: pin.tag, new_tag, old_rel: pkg.rel, new_rel, checksums: checksum_changes, warning,
  })
}

## Print a reviewable unified diff of the proposed recipe text.
export proc show_diff(name: Str, before: Str, after: Str) [fs, process, env, error] {
  tempdir work {
    let relative = f"packages/{name}/PKGBUILD.xsh"
    let old_file = fp"{work}/a/{relative}"
    let new_file = fp"{work}/b/{relative}"
    old_file.parent.mkdir()
    new_file.parent.mkdir()
    old_file.write(before)
    new_file.write(after)
    let result = cd (work) { run.capture --text git diff --no-index --no-color -- a/$relative b/$relative }?
    print result.stdout.trim()
  }
}

## Verify the proposed recipe with the PM source fetcher in a temporary catalog.
export proc verify_with_pm(name: Str, after: Str) [fs, process, env, error] {
  let xsh = process.which("xsh")?
  let pm = path.absolute(p"pm.xsh")?
  let cache = path.absolute(p".cache/sources")?.display()
  tempdir work {
    let catalog_packages = path.absolute(p"packages")?
    let _ = fs.copy_tree(catalog_packages, fp"{work}/packages", parents: true, overwrite: true)?
    fp"{work}/packages/{name}/PKGBUILD.xsh".write(after)
    let out = env ({LAPUTA_SOURCE_CACHE: cache}) {
      run.text $xsh $pm -- sources fetch --repo $work $name --target x86_64-linux-musl --target aarch64-linux-musl
    }?
    print out.trim()
  }
}

## List every recipe name in a repository catalog.
export proc catalog_names(repo_root: Path) [fs, env, error] -> Result[List[Str], Error] {
  let value = catalog.load(repo_root)?
  [pkg.name for pkg in value.packages]
}
