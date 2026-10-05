##! PM remote operations and shared package-manager policy.
use types
use util

## The package repository PM reads indexes and artifacts from and publishes to:
## XSH_PM_REPO, typically the local mirror (`http://127.0.0.1:3000`) or a
## `file://` tree. Empty means offline; there is no default remote.
export proc repo_url() [env] -> Str {
  (e"XSH_PM_REPO" ?? "").trim()
}

# The local mirror and `file://` trees accept writes without credentials.
pure remote_auth_headers(token: Str) -> List[NetHeader] {
  if token == "" {
    return []
  }

  [{name: "Authorization", value: f"Bearer {token}"}]
}

## Copies one repository object to `dest`; returns the failure text, or "" on success.
export proc try_fetch_repo_file(
  repo: Str,
  rel: Path,
  dest: Path,
  timeout: Duration = 1800s,
) [fs, net, error] -> Result[Str, Error] {
  util.download_file(util.repo_url_for(repo, rel)?, dest, timeout)?
}

## Exported PM declaration `net_put_file`.
export proc net_put_file(url: Str, source: Path, token: Str) [net, error] {
  let response = net.upload({
    method: "PUT",
    url: url,
    source: source,
    headers: remote_auth_headers(token),
    pool: "pm",
    fail_status: true,
  })?

  if response.status < 200 or response.status >= 300 {
    return Err(types.PmError.RemoteUpload(f"failed to upload {source.name}"))
  }
}

## Exported PM declaration `upload_repo_file`.
export proc upload_repo_file(repo: Str, rel: Path, source: Path, token: Str, _: Path) [fs, net, error] {
  if util.is_file_url(repo) {
    let dest = util.repo_file_path(repo, rel)?
    dest.parent.mkdir()
    source.copy(dest, overwrite: true)
    return
  }

  net_put_file(util.repo_url_for(repo, rel)?, source, token)
}

## Publishes one immutable repository object. A file remote receives a temporary copy and rename;
## an existing object is accepted only when its exact bytes already match the requested source.
export proc upload_immutable_repo_file(
  repo: Str,
  rel: Path,
  source: Path,
  token: Str,
  work: Path,
) [fs, net, error] -> Result[Bool, Error] {
  if ! util.is_file_url(repo) {
    let response = net.upload({
      method: "PUT",
      url: util.repo_url_for(repo, rel)?,
      source,
      headers: remote_auth_headers(token).push({name: "If-None-Match", value: "*"}),
      pool: "pm",
      fail_status: false,
    })?

    if response.status >= 200 and response.status < 300 {
      return true
    }

    # Objects are content-addressed, so a retried publication meets the
    # objects its failed attempt already uploaded; identical bytes are done.
    if response.status == 409 or response.status == 412 {
      let existing = fp"{work}/immutable-existing/{rel.bytes().sha256().hex()}"
      existing.parent.mkdir()
      defer existing.remove(missing_ok: true)
      let failure = try_fetch_repo_file(repo, rel, existing)?

      if failure == "" and hash.sha256(existing)?.hex() == hash.sha256(source)?.hex() {
        return false
      }

      return Err(types.PmError.PackageConflict(f"immutable remote object {rel} already exists with different bytes"))
    }

    return Err(types.PmError.RemoteUpload(f"failed to upload immutable remote object {rel}: HTTP {response.status}"))
  }

  let dest = util.repo_file_path(repo, rel)?

  if dest.exists() {
    if hash.sha256(dest)?.hex() == hash.sha256(source)?.hex() {
      return false
    }

    return Err(types.PmError.PackageConflict(f"immutable remote object {rel} already exists with different bytes"))
  }

  let temporary = fp"{dest.parent}/.{dest.name}.tmp"
  dest.parent.mkdir()
  temporary.remove(missing_ok: true)
  defer temporary.remove(missing_ok: true)
  source.copy(temporary, overwrite: true)
  temporary.rename(dest)
  true
}

## Exported PM declaration `load_remote_index_from`.
export proc load_remote_index_from(index_path: Path) [fs, error] -> Result[List[types.RemotePackage], Error] {
  if index_path.exists() {
    let rows: List[Record] = json.read(index_path)?.require(List[Record])?
    return decode_remote_index(rows)
  }

  let empty = []
  empty
}

proc try_load_remote_index_from_repo(repo: Str, out: Path) -> Result[List[types.RemotePackage]] {
  if util.is_file_url(repo) {
    return load_remote_index_from(util.repo_file_path(repo, p"index.json")?)?
  }

  # The mirror advertises a cache lifetime for index.json; PM needs the current generation.
  let response = net.request({
    method: "GET",
    url: util.repo_url_for(repo, p"index.json")?,
    headers: [{name: "Cache-Control", value: "no-cache"}, {name: "Pragma", value: "no-cache"}],
    pool: "pm",
    timeout: 15s,
    connect_timeout: 5s,
    max_body_bytes: 10485760,
  })?

  if response.status == 404 {
    let empty = []
    return empty
  }

  if response.status < 200 or response.status >= 300 {
    return Err(types.PmError.RemoteIndex(f"failed to fetch remote index: HTTP {response.status}"))
  }

  let body = response.body as Str
  let rows: List[Record] = json.decode(body)?.require(List[Record])?
  let items = decode_remote_index(rows)?
  out.mkdir()
  util.remote_index_cache_path(out).write_atomic(body)
  items
}

## Exported PM declaration `load_remote_index_from_repo`.
export proc load_remote_index_from_repo(
  repo: Str,
  out: Path,
) [fs, net, time, error] -> Result[List[types.RemotePackage], Error] {
  if util.is_file_url(repo) {
    return try_load_remote_index_from_repo(repo, out)?
  }

  retry [1s, 2s, 4s, 15s, 60s] {
    try_load_remote_index_from_repo(repo, out)?
  }?
}

## Exported PM declaration `decode_remote_index`.
export proc decode_remote_index(rows: List[Record]) [error] -> Result[List[types.RemotePackage], Error] {
  var items = [decode_remote_package(row)? for row in rows]
  items
}

## Exported PM declaration `decode_remote_package`.
export proc decode_remote_package(row: Record) [error] -> Result[types.RemotePackage, Error] {
  var arch = "aarch64"
  let empty_dependencies: List[Str] = []
  let mkdeps_host = if "mkdeps_host" in row {
    row.get("mkdeps_host")?.require(List[Str])?
  } else {
    row.get("mkdeps")?.require(List[Str])?
  }

  let mkdeps_target = if "mkdeps_target" in row {
    row.get("mkdeps_target")?.require(List[Str])?
  } else if "target_build_deps" in row {
    row.get("target_build_deps")?.require(List[Str])?
  } else {
    empty_dependencies
  }

  if "arch" in row {
    let stored_arch: Str = row.get("arch")?.require(Str)?
    arch = util.normalize_arch(stored_arch)
  }

  {
    arch,
    name: row.get("name")?.require(Str)?,
    ver: row.get("ver")?.require(Str)?,
    rel: row.get("rel")?.require(Str)?,
    deps: row.get("deps")?.require(List[Str])?,
    # Index rows written before runtime-only dependencies existed declare none.
    runtime_only_deps: if "runtime_only_deps" in row { row.get("runtime_only_deps")?.require(List[Str])? } else { empty_dependencies },
    mkdeps_host,
    mkdeps_target,
    sha256: row.get("sha256")?.require(Str)?,
    size: row.get("size")?.require(Int)?,
    tarball: row.get("tarball")?.require(Str)?,
    metadata: if "metadata" in row { row.get("metadata")?.require(Str)? } else { "" },
    metadata_sha256: if "metadata_sha256" in row { row.get("metadata_sha256")?.require(Str)? } else { "" },
    artifact_key: if "artifact_key" in row { row.get("artifact_key")?.require(Str)? } else { "" },
    recipe_sha256: if "recipe_sha256" in row { row.get("recipe_sha256")?.require(Str)? } else { "" },
    executor_sha256: if "executor_sha256" in row { row.get("executor_sha256")?.require(Str)? } else { "" },
    proof_key: if "proof_key" in row { row.get("proof_key")?.require(Str)? } else { "" },
    proof_sha256: if "proof_sha256" in row { row.get("proof_sha256")?.require(Str)? } else { "" },
    proof: if "proof" in row { row.get("proof")?.require(Str)? } else { "" },
    proof_receipt_sha256: if "proof_receipt_sha256" in row { row.get("proof_receipt_sha256")?.require(Str)? } else { "" },
    source_sha256: row.get("source_sha256")?.require(Str)?,
    metapackage: row.get("metapackage")?.require(Bool)?,
  }
}

## Exported PM declaration `write_remote_index_cache`.
export proc write_remote_index_cache(out: Path, index: List[types.RemotePackage]) [fs, error] {
  out.mkdir()
  json.write(util.remote_index_cache_path(out), index)
}

## Exported PM declaration `write_remote_index_to_repo`.
export proc write_remote_index_to_repo(
  repo: Str,
  work: Path,
  out: Path,
  index: List[types.RemotePackage],
  token: Str,
) [fs, net, error] {
  write_remote_index_cache(out, index)

  if util.is_file_url(repo) {
    let dest = util.repo_file_path(repo, p"index.json")?
    let temporary = fp"{dest.parent}/.{dest.name}.tmp"
    dest.parent.mkdir()
    temporary.remove(missing_ok: true)
    defer temporary.remove(missing_ok: true)
    util.remote_index_cache_path(out).copy(temporary, overwrite: true)
    temporary.rename(dest, overwrite: true)
    return
  }

  upload_repo_file(repo, p"index.json", util.remote_index_cache_path(out), token, work)
}

## Exported PM declaration `upsert_remote_package`.
export proc upsert_remote_package(
  index: List[types.RemotePackage],
  entry: types.RemotePackage,
) [error] -> Result[List[types.RemotePackage], Error] {
  var updated = []
  var replaced = false

  for existing in index {
    if existing.arch == entry.arch and existing.name == entry.name {
      updated += [entry]
      replaced = true
    } else {
      updated += [existing]
    }
  }

  if ! replaced {
    updated += [entry]
  }

  let sorted = updated |> sort-by .name
  sorted
}

# Derives the legacy retrieval fingerprint kept for index rows that predate immutable metadata sidecars.
pure legacy_snapshot_digest(value: types.RemotePackage) -> Str {
  var lines = [
    "format\tlaputa-legacy-remote-entry-1",
    f"arch\t{value.arch}",
    f"name\t{value.name}",
    f"ver\t{value.ver}",
    f"rel\t{value.rel}",
    f"sha256\t{value.sha256}",
    f"tarball\t{value.tarball}",
    f"metadata\t{value.metadata}",
    f"source-sha256\t{value.source_sha256}",
    f"metapackage\t{value.metapackage}",
  ]

  for dependency in value.deps |> sort {
    lines += [f"runtime\t{dependency}"]
  }

  for dependency in value.mkdeps_host |> sort {
    lines += [f"build-host\t{dependency}"]
  }

  for dependency in value.mkdeps_target |> sort {
    lines += [f"build-target\t{dependency}"]
  }

  bytes.from_text(lines.join("\n") + "\n").sha256().hex()
}

## Decodes new immutable index identities while retaining the legacy empty-identity fallback.
export proc plan_artifact_from_package(value: types.RemotePackage) [error] -> Result[types.RemotePlanArtifact, Error] {
  let fields = [value.artifact_key, value.recipe_sha256, value.executor_sha256, value.proof_key, value.proof_sha256]
  let populated = [field for field in fields if field != ""]

  if ! populated.is_empty() and populated.len() != fields.len() {
    return Err(types.PmError.PackageContract(f"remote package {value.name} has a partial immutable identity"))
  }

  let fallback = legacy_snapshot_digest(value)
  let tarball = if value.tarball == "" {
    util.legacy_remote_binary_rel(value.arch, value.name, value.ver, value.rel).display()
  } else {
    value.tarball
  }
  let metadata = if value.metadata == "" {
    util.legacy_remote_metadata_rel(value.arch, value.name, value.ver, value.rel).display()
  } else {
    value.metadata
  }

  {
    name: value.name,
    ver: value.ver,
    rel: value.rel,
    retrieval: {
      arch: value.arch,
      tarball,
      tarball_sha256: if value.sha256 == "" { fallback } else { value.sha256 },
      metadata,
      metadata_sha256: if value.metadata_sha256 == "" { fallback } else { value.metadata_sha256 },
    },
    artifact_key: value.artifact_key,
    recipe_sha256: value.recipe_sha256,
    executor_sha256: value.executor_sha256,
    proof_key: value.proof_key,
    proof_sha256: value.proof_sha256,
  }
}

proc remote_legacy_metadata_rel(value: types.RemotePackage) -> Result[Path] {
  let raw = if value.metadata == "" {
    util.legacy_remote_metadata_rel(value.arch, value.name, value.ver, value.rel).display()
  } else {
    value.metadata
  }

  util.ensure_relative_path(fp"{raw}", f"remote metadata for {value.name}")?
}

## Resolves the omitted metadata hash in a legacy index into the exact retrieval bytes recorded in a BuildPlan.
## Modern rows already carry that digest and require no additional request.
export proc plan_artifact_from_package_at_repo(
  value: types.RemotePackage,
  repo: Str,
  cache: Path,
) [fs, net, error] -> Result[types.RemotePlanArtifact, Error] {
  if value.metadata_sha256 != "" {
    return plan_artifact_from_package(value)?
  }

  if repo == "" {
    return Err(
      types.PmError.RemoteRepo(f"legacy remote package {value.name} needs a repository URL to hash its metadata"),
    )
  }

  let rel = remote_legacy_metadata_rel(value)?
  let cache_path = fp"{cache}/legacy-metadata/{rel.bytes().sha256().hex()}.json"
  let failure = try_fetch_repo_file(repo, rel, cache_path)?

  if failure != "" {
    return Err(types.PmError.RemoteFetch(failure))
  }

  let metadata_sha256 = hash.sha256(cache_path)?.hex()
  plan_artifact_from_package({...value, metadata: rel.display(), metadata_sha256})?
}
