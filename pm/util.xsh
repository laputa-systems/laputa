##! PM util operations and shared package-manager policy.
use types

## Exported PM declaration `package_id`.
export pure package_id(name: Str, ver: Str, rel: Str) -> Str {
  f"{name}-{ver}-{rel}"
}

## Exported PM declaration `version_id`.
export pure version_id(ver: Str, rel: Str) -> Str {
  f"{ver}-{rel}"
}

## Exported PM declaration `packages_db_path`.
export pure packages_db_path(root: Path) -> Path {
  fp"{root}/var/lib/xsh-pm/packages"
}

## Exported PM declaration `package_db_path`.
export pure package_db_path(root: Path, name: Str) -> Path {
  fp"{packages_db_path(root)}/{name}"
}

## Exported PM declaration `remote_index_cache_path`.
export pure remote_index_cache_path(out: Path) -> Path {
  fp"{out}/remote-index.json"
}

# Remote package objects are content-addressed and therefore immutable: a
# rebuild under the same ver-rel (a new seed, a PM edit, a rebuilt
# dependency) gets new object names instead of overwriting the old ones, and
# the index row is the only mutable pointer. The payload is named by its
# artifact key; metadata and proof also carry the proof key, because a
# proof-only change re-proves the same payload with a new proof receipt and
# metadata. Twelve hex digits of each key keep names readable; the index row
# carries the full keys.
pure remote_key_prefix(key: Str) -> Str {
  key.byte_slice(0, 12)
}

pure remote_object_stem(name: Str, ver: Str, rel: Str, artifact_key: Str) -> Str {
  f"{package_id(name, ver, rel)}-{remote_key_prefix(artifact_key)}"
}

## `packages/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>.tar.gz`.
export pure remote_binary_rel(arch: Str, name: Str, ver: Str, rel: Str, artifact_key: Str) -> Path {
  fp"packages/{arch}/{name}/{remote_object_stem(name, ver, rel, artifact_key)}.tar.gz"
}

## `metadata/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json`.
export pure remote_metadata_rel(arch: Str, name: Str, ver: Str, rel: Str, artifact_key: Str, proof_key: Str) -> Path {
  fp"metadata/{arch}/{name}/{remote_object_stem(name, ver, rel, artifact_key)}-{remote_key_prefix(proof_key)}.json"
}

## `proofs/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json`.
export pure remote_proof_rel(arch: Str, name: Str, ver: Str, rel: Str, artifact_key: Str, proof_key: Str) -> Path {
  fp"proofs/{arch}/{name}/{remote_object_stem(name, ver, rel, artifact_key)}-{remote_key_prefix(proof_key)}.json"
}

## Legacy payload name of index rows that predate artifact keys and omit `tarball`.
export pure legacy_remote_binary_rel(arch: Str, name: Str, ver: Str, rel: Str) -> Path {
  fp"packages/{arch}/{name}/{package_id(name, ver, rel)}.tar.gz"
}

## Legacy metadata name of index rows that predate artifact keys and omit `metadata`.
export pure legacy_remote_metadata_rel(arch: Str, name: Str, ver: Str, rel: Str) -> Path {
  fp"metadata/{arch}/{name}/{package_id(name, ver, rel)}.json"
}

## Exported PM declaration `ensure_relative_path`.
export pure ensure_relative_path(path_value: Path, label: Str) -> Result[Path] {
  let normalized = path_value.normalize()
  let text = normalized.display()

  if text.starts_with("/") {
    return Err(types.PmError.SourceDestination(f"{label} must stay relative: {path_value}"))
  }

  for component in text.split("/") {
    if component == ".." {
      return Err(types.PmError.SourceDestination(f"{label} must stay relative: {path_value}"))
    }
  }

  normalized
}

## Exported PM declaration `is_file_url`.
export pure is_file_url(url: Str) -> Bool {
  url.starts_with("file://")
}

## Exported PM declaration `file_url_path`.
export pure file_url_path(url: Str) -> Result[Path] {
  fp"{url.replace("file://", "")}"
}

## Exported PM declaration `repo_file_path`.
export pure repo_file_path(repo: Str, rel: Path) -> Result[Path] {
  fp"{file_url_path(repo)?}/{ensure_relative_path(rel, "repo path")?}"
}

## Exported PM declaration `repo_url_for`.
export pure repo_url_for(repo: Str, rel: Path) -> Result[Str] {
  f"{repo}/{ensure_relative_path(rel, "repo path")?.display()}"
}

## Exported PM declaration `is_tar_source`.
export pure is_tar_source(candidate: Path) -> Bool {
  let name = candidate.name

  name.ends_with(".tar") or name.ends_with(".tar.gz") or name.ends_with(".tgz") or name.ends_with(".tar.bz2") or name.ends_with(
    ".tbz2",
  ) or name.ends_with(".tar.xz") or name.ends_with(".txz") or name.ends_with(".tar.lzma") or name.ends_with(".crate")
}

## Exported PM declaration `is_zip_source`.
export pure is_zip_source(candidate: Path) -> Bool {
  candidate.name.ends_with(".zip")
}

## Exported PM declaration `is_cpio_source`.
export pure is_cpio_source(candidate: Path) -> Bool {
  candidate.name.ends_with(".cpio")
}

## Exported PM declaration `is_etc_file`.
export pure is_etc_file(candidate: Path) -> Bool {
  candidate.display().starts_with("etc/")
}

## Exported PM declaration `is_url_source`.
export pure is_url_source(source: Str) -> Bool {
  "://" in source
}

## The file name a URL source stages under, without query or fragment.
export pure source_basename(source: Str) -> Result[Str] {
  let parsed_path = fp"{source.split("#")[0].split("?")[0]}"
  parsed_path.name
}

## Exported PM declaration `parse_source_line`.
export pure parse_source_line(raw: Path) -> Result[types.SourceLine] {
  let raw_text = raw.display()
  let spaced = raw_text.split(" => ")

  return {source: spaced[0].trim(), dest: fp"{spaced[1].trim()}"} when spaced.len() > 1

  let tight = raw_text.split("=>")

  return {source: tight[0].trim(), dest: fp"{tight[1].trim()}"} when tight.len() > 1

  {source: raw_text, dest: p"."}
}

## Exported PM declaration `source_stage_dir`.
export pure source_stage_dir(src: Path, line: types.SourceLine) -> Path {
  let dest = line.dest.normalize()

  return src when dest.display() == "."

  fp"{src}/{dest}"
}

## Exported PM declaration `goarch_for`.
export pure goarch_for(arch: Str) -> Str {
  return "arm64" when arch == "aarch64" or arch == "arm64"

  return "amd64" when arch == "x86_64"

  arch
}

# Placeholders are whole uppercase words in a source string. Matching words
# rather than substrings keeps names such as PATCH, PACKAGE, or SEARCH from
# being rewritten through the ARCH or other placeholders they contain.
const source_placeholder_word = rx"[A-Z]+"

## Substitutes each whole-word placeholder in `source` from `values` in one pass.
## A placeholder is a run of uppercase ASCII letters, or two such runs joined by
## one `_` (`TARGET_ARCH`); lowercase letters, digits, and punctuation delimit it,
## so `vVERSION` and `tailscale_VERSION_GOARCH` expand while `PATCHES` does not.
## Substituted values are never rescanned.
export pure expand_source_placeholders(source: Str, values: Map[Str]) -> Str {
  let words = source_placeholder_word.find(source)
  var expanded = ""
  var cursor = 0
  var index = 0

  while index < words.len() {
    let word = words[index]
    var name = word.text
    var end = word.end

    if index + 1 < words.len() {
      let next = words[index + 1]
      let joined = f"{word.text}_{next.text}"

      if next.start == word.end + 1 and source.byte_slice(word.end, 1) == "_" and joined in values {
        name = joined
        end = next.end
        index += 1
      }
    }

    if name in values {
      expanded = expanded + source.byte_slice(cursor, word.start - cursor) + (values.get(name) ?? "")
      cursor = end
    }

    index += 1
  }

  expanded + source.byte_slice(cursor)
}

## The placeholder values a recipe source string may name for one target and build architecture.
export pure source_placeholder_values(pkg: types.Package, arch: Str, build: Str) -> Map[Str] {
  let parts = pkg.ver.replace("+", ".").replace("-", ".").replace("_", ".").split(".")

  {
    VERSION: pkg.ver,
    RELEASE: pkg.rel,
    MAJOR: parts.get(0) ?? "",
    MINOR: parts.get(1) ?? "",
    PATCH: parts.get(2) ?? "",
    IDENT: parts.get(3) ?? "",
    PACKAGE: pkg.name,
    TARGET_TRIPLE: f"{arch}-linux-musl",
    BUILD_TRIPLE: f"{build}-linux-musl",
    TARGET_GOARCH: goarch_for(arch),
    BUILD_GOARCH: goarch_for(build),
    TARGET_ARCH: arch,
    BUILD_ARCH: build,
    GOARCH: goarch_for(arch),
    ARCH: arch,
  }
}

## Expands a recipe source string for one target and build architecture.
export pure expand_source(source: Str, pkg: types.Package, arch: Str, build: Str) -> Str {
  expand_source_placeholders(source, source_placeholder_values(pkg, arch, build))
}

## True for repositories PM may write without a token: `file://` trees and the
## loopback-only local mirror (`http://127.0.0.1[:PORT]` or `http://localhost[:PORT]`).
export pure is_local_repo_url(url: Str) -> Bool {
  is_file_url(url) or rx"^http://(127\.0\.0\.1|localhost)(:[0-9]+)?(/.*)?$".matches(url)
}

## Downloads one `http(s)://` or `file://` URL to `dest` and returns the failure
## text, or "" on success. `dest` only ever holds complete bytes. net.download
## follows redirects itself, so release hosts and mirrors that redirect need no
## separate probe.
export proc download_file(url: Str, dest: Path, timeout: Duration = 1800s) [fs, net, error] -> Result[Str] {
  fs.mkdir(dest.parent)?

  if is_file_url(url) {
    let source = file_url_path(url)?

    return f"{url}: missing file" unless fs.exists(source)?

    let partial = fp"{dest.parent}/.{dest.name}.partial"
    fs.copy(source, partial, overwrite: true)?
    fs.rename(partial, dest, overwrite: true)?
    return ""
  }

  match net.download({
    url,
    dest,
    atomic: true,
    overwrite: true,
    pool: "pm",
    connect_timeout: 10s,
    timeout,
    fail_status: true,
  }) {
    Ok(_) => ""
    Err(problem) => f"{url}: {problem.message}"
  }
}

## Exported PM declaration `host_arch`.
export proc host_arch() [env, error] -> Result[Str] {
  let os = system.uname()?
  normalize_arch(os.machine)
}

## Exported PM declaration `build_arch`.
export proc build_arch() [env, error] -> Result[Str] {
  let override = (env.get("XSH_PM_BUILD_ARCH") ?? "").trim()

  return normalize_arch(override) when override != ""

  host_arch()?
}

## Exported PM declaration `target_arch`.
export proc target_arch() [env, error] -> Result[Str] {
  let target_override = (env.get("XSH_PM_TARGET_ARCH") ?? "").trim()

  return normalize_arch(target_override) when target_override != ""

  let legacy_override = (env.get("XSH_PM_ARCH") ?? "").trim()

  return normalize_arch(legacy_override) when legacy_override != ""

  host_arch()?
}

## Exported PM declaration `machine_arch`.
export proc machine_arch() [env, error] -> Result[Str] {
  target_arch()?
}

## Exported PM declaration `normalize_arch`.
export pure normalize_arch(arch: Str) -> Str {
  return "aarch64" when arch == "arm64"

  return "x86_64" when arch == "amd64"

  arch
}
