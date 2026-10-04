##! Immutable package artifacts addressed by semantic SHA-256 keys; finals appear only after a temporary-directory rename, and XSH reserves standard `path`, so exports use `artifact_path`.
# Object hashes are computed once, when an artifact is committed, and recorded
# in its receipt. Lookups trust a committed directory and do not re-hash it;
# `verify_artifact`, `verify_receipt`, and `verify_all` re-hash on request.
use remote
use types
use util

type ArtifactReceiptDto = {
  format: Str,
  key: Str,
  target: Str,
  package_name: Str,
  package_id: Str,
  origin: Str,
  recipe_sha256: Str,
  executor_sha256: Str,
  payload_sha256: Str,
  metadata_sha256: Str,
  proof_key: Str,
  proof_sha256: Str,
  dependency_keys: List[Str],
  runtime_dependency_keys: List[Str],
}

type RemoteMetadataDto = {name: Str, ver: Str, rel: Str}

type ReceiptFormatDto = {format: Str}

## The receipt format this Store writes and reads.
export const receipt_format = "laputa-package-artifact-2"

# The layout directory is versioned with the artifact-key format. Keys of an
# older format live under their own directory (`v1/`), which this PM never
# reads, so old and new artifacts cannot mix.
pure store_layout(root: Path) -> Path {
  fp"{root}/v2"
}

pure object_root(root: Path) -> Path {
  fp"{store_layout(root)}/sha256"
}

pure lock_path(root: Path, key: Str) -> Path {
  fp"{store_layout(root)}/locks/{key}.lock"
}

pure temporary_path(root: Path, key: Str) -> Path {
  fp"{store_layout(root)}/tmp/{key}"
}

pure receipt_path(dir: Path) -> Path {
  fp"{dir}/artifact.json"
}

pure payload_path(dir: Path) -> Path {
  fp"{dir}/payload.tar.gz"
}

pure metadata_path(dir: Path) -> Path {
  fp"{dir}/metadata.json"
}

pure proof_path(dir: Path) -> Path {
  fp"{dir}/proof.json"
}

pure sha256_text_is_valid(value: Str) -> Bool {
  value.count_chars() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

proc require_sha256(value: Str, label: Str) [error] {
  guard sha256_text_is_valid(value) else {
    return Err(types.PmError.PackageContract(f"{label} must be a lowercase SHA-256 digest"))
  }
}

proc require_key(key: Str) [error] {
  require_sha256(key, "artifact key")?
}

pure store_unique_artifact_keys(keys: List[Str]) -> List[Str] {
  var seen: Map[Bool] = {}
  var result: List[Str] = []

  for key in keys {
    if ! (key in seen) {
      seen[key] = true
      result += [key]
    }
  }

  result
}

## Returns canonical artifact identities for every build-input PlanNode dependency edge.
## A receipt does not serialize edge kinds: shared Runtime and BuildHost artifacts retain
## their first planned occurrence exactly once while PlanNode keeps the complete edge list.
## Runtime-only edges are absent: they are no artifact-key input, so one artifact (and its
## receipt) serves every plan whatever runtime-only artifacts that plan pairs with it.
## Root composition reads them from the plan instead.
export pure receipt_dependency_keys(node: types.PlanNode) -> List[Str] {
  store_unique_artifact_keys(
    [
      dependency.artifact_key
      for dependency in node.dependencies
      if dependency.kind != types.dependency_runtime_only()
    ],
  )
}

## Returns the canonical runtime-only subset of `receipt_dependency_keys`.
export pure receipt_runtime_dependency_keys(node: types.PlanNode) -> List[Str] {
  store_unique_artifact_keys(
    [
      dependency.artifact_key
      for dependency in node.dependencies
      if dependency.kind == types.dependency_runtime()
    ],
  )
}

pure receipt_dto(value: types.ArtifactReceipt) -> ArtifactReceiptDto {
  {
    format: value.format,
    key: value.key,
    target: types.target_text(value.target),
    package_name: value.package_name,
    package_id: value.package_id,
    origin: types.artifact_origin_text(value.origin),
    recipe_sha256: value.recipe_sha256,
    executor_sha256: value.executor_sha256,
    payload_sha256: value.payload_sha256,
    metadata_sha256: value.metadata_sha256,
    proof_key: value.proof_key,
    proof_sha256: value.proof_sha256,
    dependency_keys: value.dependency_keys,
    runtime_dependency_keys: value.runtime_dependency_keys,
  }
}

proc receipt_from_dto(value: ArtifactReceiptDto, artifact_dir: Path) [error] -> Result[types.ArtifactReceipt] {
  {
    format: value.format,
    key: value.key,
    target: types.parse_target(value.target)?,
    package_name: value.package_name,
    package_id: value.package_id,
    origin: types.parse_artifact_origin(value.origin)?,
    recipe_sha256: value.recipe_sha256,
    executor_sha256: value.executor_sha256,
    payload_sha256: value.payload_sha256,
    metadata_sha256: value.metadata_sha256,
    proof_key: value.proof_key,
    proof_sha256: value.proof_sha256,
    dependency_keys: value.dependency_keys,
    runtime_dependency_keys: value.runtime_dependency_keys,
    artifact_dir,
  }
}

proc validate_receipt(value: types.ArtifactReceipt, expected_key: Str) [error] {
  guard value.format == receipt_format else {
    return Err(types.PmError.PackageContract(f"unsupported artifact receipt format {value.format}"))
  }

  require_key(expected_key)?
  require_key(value.key)?

  if value.key != expected_key {
    return Err(types.PmError.PackageContract(f"artifact receipt key {value.key} does not match {expected_key}"))
  }

  if types.pm_target_arch(value.target) == "" {
    return Err(types.PmError.PackageContract("artifact receipt has an unsupported target"))
  }

  if value.package_name == "" or "\n" in value.package_name {
    return Err(types.PmError.PackageContract("artifact receipt package_name is invalid"))
  }

  if value.package_id == "" or "\n" in value.package_id {
    return Err(types.PmError.PackageContract("artifact receipt package_id is invalid"))
  }

  require_sha256(value.recipe_sha256, "artifact receipt recipe_sha256")?
  require_sha256(value.executor_sha256, "artifact receipt executor_sha256")?
  require_sha256(value.payload_sha256, "artifact receipt payload_sha256")?
  require_sha256(value.metadata_sha256, "artifact receipt metadata_sha256")?
  require_sha256(value.proof_key, "artifact receipt proof_key")?
  require_sha256(value.proof_sha256, "artifact receipt proof_sha256")?

  var seen: Map[Bool] = {}

  for dependency_key in value.dependency_keys {
    require_sha256(dependency_key, "artifact receipt dependency key")?

    if dependency_key in seen {
      return Err(types.PmError.PackageContract(f"artifact receipt repeats dependency key {dependency_key}"))
    }

    seen[dependency_key] = true
  }

  var seen_runtime: Map[Bool] = {}

  for dependency_key in value.runtime_dependency_keys {
    require_sha256(dependency_key, "artifact receipt runtime dependency key")?

    if ! (dependency_key in seen) {
      return Err(
        types.PmError.PackageContract(f"artifact receipt runtime dependency key {dependency_key} is not a dependency"),
      )
    }

    if dependency_key in seen_runtime {
      return Err(types.PmError.PackageContract(f"artifact receipt repeats runtime dependency key {dependency_key}"))
    }

    seen_runtime[dependency_key] = true
  }
}

# Reads and validates a receipt and checks that its objects exist, without hashing them.
proc read_receipt(dir: Path, expected_key: Str) [fs, error] -> Result[types.ArtifactReceipt] {
  let raw = json.read(receipt_path(dir))?
  # Check the format before the DTO so a receipt from another Store schema
  # names its format instead of failing on a missing field.
  let format_field = raw.require(ReceiptFormatDto)?.format

  if format_field != receipt_format {
    return Err(
      types.PmError.PackageContract(
        f"artifact {expected_key} has unsupported receipt format {format_field}; this PM reads {receipt_format}",
      ),
    )
  }

  let value = receipt_from_dto(raw.require()?, dir)?
  validate_receipt(value, expected_key)?

  if ! fs.exists(payload_path(dir))? or ! fs.exists(metadata_path(dir))? or ! fs.exists(proof_path(dir))? {
    return Err(types.PmError.PackageContract(f"artifact {expected_key} is incomplete"))
  }

  value
}

proc verify_dir(dir: Path, expected_key: Str) [fs, error] -> Result[types.ArtifactReceipt] {
  let value = read_receipt(dir, expected_key)?
  let payload = payload_path(dir)
  let metadata = metadata_path(dir)
  let proof = proof_path(dir)
  let actual_payload = hash.sha256(payload)?.hex()

  if actual_payload != value.payload_sha256 {
    return Err(types.PmError.PackageContract(f"artifact {expected_key} payload SHA-256 does not match receipt"))
  }

  let actual_metadata = hash.sha256(metadata)?.hex()

  if actual_metadata != value.metadata_sha256 {
    return Err(types.PmError.PackageContract(f"artifact {expected_key} metadata SHA-256 does not match receipt"))
  }

  let actual_proof = hash.sha256(proof)?.hex()

  if actual_proof != value.proof_sha256 {
    return Err(types.PmError.PackageContract(f"artifact {expected_key} proof SHA-256 does not match receipt"))
  }

  value
}

proc receipt_for(
  target: types.Target,
  node: types.PlanNode,
  dir: Path,
  payload_sha256: Str,
  executor_sha256: Str,
  origin: types.ArtifactOrigin,
) [fs, error] -> Result[types.ArtifactReceipt] {
  require_key(node.artifact_key)?
  require_sha256(node.recipe_sha256, "plan node recipe_sha256")?
  require_sha256(node.proof_key, "plan node proof_key")?
  require_sha256(executor_sha256, "staged executor_sha256")?
  require_sha256(payload_sha256, "staged payload_sha256")?

  let payload = payload_path(dir)
  let metadata = metadata_path(dir)
  let proof = proof_path(dir)

  if ! fs.exists(payload)? or ! fs.exists(metadata)? or ! fs.exists(proof)? {
    return Err(types.PmError.PackageContract(f"staged artifact for {node.package_id} is incomplete"))
  }

  {
    format: receipt_format,
    key: node.artifact_key,
    target,
    package_name: node.name,
    package_id: node.package_id,
    origin,
    recipe_sha256: node.recipe_sha256,
    executor_sha256,
    payload_sha256,
    metadata_sha256: hash.sha256(metadata)?.hex(),
    proof_key: node.proof_key,
    proof_sha256: hash.sha256(proof)?.hex(),
    dependency_keys: receipt_dependency_keys(node),
    runtime_dependency_keys: receipt_runtime_dependency_keys(node),
    artifact_dir: dir,
  }
}

proc write_receipt(dir: Path, value: types.ArtifactReceipt) [fs, error] {
  fs.write(receipt_path(dir), json.encode(receipt_dto(value))? + "\n")?
}

proc copy_staged(dir: Path, staged: types.StagedArtifact) [fs, error] {
  fs.copy(staged.payload, payload_path(dir))?
  fs.copy(staged.metadata, metadata_path(dir))?
  fs.copy(staged.proof, proof_path(dir))?
}

proc commit_locked(
  target: types.Target,
  root: Path,
  node: types.PlanNode,
  staged: types.StagedArtifact,
  origin: types.ArtifactOrigin,
) [fs, error] -> Result[types.ArtifactReceipt] {
  let key = node.artifact_key
  let final_dir = artifact_path(root, key)

  if fs.exists(final_dir)? {
    let existing = read_receipt(final_dir, key)?
    if existing.target != target {
      return Err(
        types.PmError.PackageContract(f"artifact {key} target does not match requested {types.target_text(target)}"),
      )
    }

    return existing
  }

  let temporary = temporary_path(root, key)
  fs.remove(temporary, missing_ok: true)?
  defer fs.remove(temporary, missing_ok: true)?
  fs.mkdir(temporary)?
  copy_staged(temporary, staged)?
  # The staged payload digest was computed when the payload was produced or
  # downloaded; hashing the copy again would only re-read the same bytes.
  let value = receipt_for(target, node, temporary, staged.payload_sha256, staged.executor_sha256, origin)?

  # artifact.json is intentionally the final temporary write: a directory with it is complete.
  write_receipt(temporary, value)?
  fs.mkdir(final_dir.parent)?
  fs.rename(temporary, final_dir)?
  read_receipt(final_dir, key)
}

proc commit_staged(
  target: types.Target,
  root: Path,
  node: types.PlanNode,
  staged: types.StagedArtifact,
  origin: types.ArtifactOrigin,
) [fs, error] -> Result[types.ArtifactReceipt] {
  if types.pm_target_arch(target) == "" {
    return Err(types.PmError.PackageContract("artifact commit target is unsupported"))
  }

  let key = node.artifact_key
  require_key(key)?
  let lock_file = lock_path(root, key)
  fs.mkdir(lock_file.parent)?
  let lock = fs.lock(lock_file)?
  defer fs.unlock(lock)?
  commit_locked(target, root, node, staged, origin)?
}

proc fetch_remote_object(
  remote_repo: Str,
  rel: Path,
  cache_path: Path,
  expected_sha256: Str,
  label: Str,
) [fs, net, error] {
  require_sha256(expected_sha256, f"remote {label} SHA-256")?
  let failure = remote.try_fetch_repo_file(remote_repo, util.ensure_relative_path(rel, f"remote {label}")?, cache_path)?

  return Err(types.PmError.RemoteFetch(failure)) when failure != ""

  let actual = hash.sha256(cache_path)?.hex()

  if actual != expected_sha256 {
    fs.remove(cache_path, missing_ok: true)?
    return Err(types.PmError.RemoteFetch(f"remote {label} SHA-256 mismatch: expected {expected_sha256}, got {actual}"))
  }
}

proc remote_executor_sha256(metadata: Path, node: types.PlanNode) [fs, error] -> Result[Str] {
  let dto = json.read(metadata)?.require(RemoteMetadataDto)?

  if dto.name != node.name or dto.ver != node.ver or dto.rel != node.rel {
    return Err(types.PmError.PackageContract(f"remote metadata does not match plan node {node.package_id}"))
  }

  # Legacy package metadata did not record an executor digest. Its verified metadata digest is a stable fallback.
  let raw = json.read(metadata)?.require(Record)?
  let value: Str = if "executor_sha256" in raw {
    raw.get("executor_sha256")?.require()?
  } else {
    hash.sha256(metadata)?.hex()
  }
  require_sha256(value, "remote metadata executor_sha256")?
  value
}

proc remote_staged_artifact_for(
  node: types.PlanNode,
  retrieval: types.RemoteRetrieval,
  remote_repo: Str,
  cache: Path,
) [fs, net, error] -> Result[types.StagedArtifact] {
  require_key(node.artifact_key)?
  let cache_dir = fp"{cache}/{node.artifact_key}"
  let payload = fp"{cache_dir}/payload.tar.gz"
  let metadata = fp"{cache_dir}/metadata.json"
  let proof = fp"{cache_dir}/proof.json"
  fs.mkdir(cache_dir)?
  fetch_remote_object(remote_repo, fp"{retrieval.tarball}", payload, retrieval.tarball_sha256, "payload")?
  fetch_remote_object(remote_repo, fp"{retrieval.metadata}", metadata, retrieval.metadata_sha256, "metadata")?
  let executor_sha256 = remote_executor_sha256(metadata, node)?
  # fetch_remote_object verified the payload against this digest.
  let payload_sha256 = retrieval.tarball_sha256
  fs.write_atomic(
    proof,
    json.encode({
      format: "laputa-package-proof-1",
      origin: "remote",
      package_id: node.package_id,
      proof_key: node.proof_key,
      proof_input_sha256: node.proof_sha256,
      metadata_sha256: retrieval.metadata_sha256,
    })? + "\n",
  )?
  {payload, payload_sha256, metadata, proof, executor_sha256}
}

proc remote_staged_artifact(
  node: types.PlanNode,
  remote_repo: Str,
  cache: Path,
) [fs, net, error] -> Result[types.StagedArtifact] {
  let retrieval = node.remote

  if retrieval != null {
    return remote_staged_artifact_for(node, retrieval, remote_repo, cache)
  }

  Err(types.PmError.PackageContract(f"remote artifact {node.package_id} has no retrieval coordinates"))
}

## Returns the canonical final directory for an artifact key. `path` is reserved by XSH's standard module namespace, so `artifact_path` is the strict-safe spelling.
export pure artifact_path(root: Path, key: Str) -> Path {
  fp"{object_root(root)}/{key}"
}

## Returns one completed artifact's validated receipt without re-hashing its objects.
## A final directory appears only through `commit`, which recorded those hashes; use
## `verify_artifact` where an artifact must be re-checked against its receipt.
export proc lookup(root: Path, key: Str) [fs, error] -> Result[types.ArtifactReceipt] {
  require_key(key)?
  let final_dir = artifact_path(root, key)

  if ! fs.exists(final_dir)? {
    return Err(types.PmError.PackageTarball(f"artifact {key} is missing"))
  }

  read_receipt(final_dir, key)
}

## Returns the immutable proof receipt path for an artifact re-proved under a newer proof key.
export pure reproof_receipt_path(root: Path, artifact_key: Str, proof_key: Str) -> Path {
  fp"{store_layout(root)}/proofs/{artifact_key}/{proof_key}.json"
}

## Re-verifies a receipt at its returned immutable artifact directory before another domain consumes its payload.
export proc verify_receipt(value: types.ArtifactReceipt) [fs, error] -> Result[types.ArtifactReceipt] {
  verify_dir(value.artifact_dir, value.key)
}

## Commits one locally built artifact through a locked temporary directory and an atomic final rename.
export proc commit(
  target: types.Target,
  root: Path,
  node: types.PlanNode,
  staged: types.StagedArtifact,
) [fs, error] -> Result[types.ArtifactReceipt] {
  commit_staged(target, root, node, staged, types.artifact_origin_built())?
}

## Imports one exact remote artifact into the immutable store without re-resolving remote metadata.
export proc import_remote(
  target: types.Target,
  root: Path,
  node: types.PlanNode,
  remote_repo: Str,
  cache: Path,
) [fs, net, error] -> Result[types.ArtifactReceipt] {
  if types.pm_target_arch(target) == "" {
    return Err(types.PmError.PackageContract("artifact import target is unsupported"))
  }

  let key = node.artifact_key
  require_key(key)?
  let lock_file = lock_path(root, key)
  fs.mkdir(lock_file.parent)?
  let lock = fs.lock(lock_file)?
  defer fs.unlock(lock)?

  if fs.exists(artifact_path(root, key))? {
    let existing = lookup(root, key)?
    if existing.target != target {
      return Err(
        types.PmError.PackageContract(f"artifact {key} target does not match requested {types.target_text(target)}"),
      )
    }

    return existing
  }

  commit_locked(target, root, node, remote_staged_artifact(node, remote_repo, cache)?, types.artifact_origin_remote())?
}

## Verifies a completed artifact receipt, its key, and hashes of payload, metadata, and proof objects.
## XSH currently lowers exported user-module procedures into one runtime symbol table: keeping this as `verify` would collide with the required `root.verify` when root imports this module. `verify_artifact` is therefore the unambiguous store boundary; no `verify` alias may be added.
export proc verify_artifact(root: Path, key: Str) [fs, error] -> Result[types.ArtifactReceipt] {
  require_key(key)?
  let final_dir = artifact_path(root, key)

  if ! fs.exists(final_dir)? {
    return Err(types.PmError.PackageTarball(f"artifact {key} is missing"))
  }

  verify_dir(final_dir, key)
}

## Verifies every completed immutable object beneath one Store root in canonical key order.
## Temporary directories and locks are intentionally ignored because they never constitute artifacts.
export proc verify_all(root: Path) [fs, error] -> Result[List[types.ArtifactReceipt]] {
  let objects = object_root(root)

  return [] unless fs.exists(objects)?

  var receipts: List[types.ArtifactReceipt] = []

  for entry in fs.children(objects)? |> sort-by .name {
    guard entry.kind == "dir" else {
      return Err(types.PmError.PackageContract(f"artifact store object {entry.path} is not a directory"))
    }

    receipts = receipts.push(verify_artifact(root, entry.name)?)
  }

  receipts
}

## What one garbage collection removed.
export type StoreGcResult = {artifacts: Int, kept: Int}

# The store only grows: every rebuild under a new key adds an artifact, and
# nothing else ever removes one. A collection keeps exactly the artifacts in
# `keep` (the keys of the plans still in use), with their re-proof receipts,
# and removes every other final artifact, its proofs and lock, and any
# interrupted temporary build. It must not run while a build writes the store.
## Remove every artifact not in `keep`, with its proofs, lock, and temporary state.
export proc gc(root: Path, keep: List[Str]) [fs, error] -> Result[StoreGcResult] {
  for key in keep {
    require_key(key)?
  }

  let kept: Map[Bool] = {key: true for key in keep}
  var removed = 0
  var remaining = 0
  let objects = object_root(root)

  if fs.exists(objects)? {
    for entry in fs.children(objects)? |> sort-by .name {
      if kept.get(entry.name) ?? false {
        remaining += 1
        continue
      }

      # fs.remove deletes a directory tree without following symlinks.
      fs.remove(entry.path)?
      fs.remove(fp"{store_layout(root)}/proofs/{entry.name}", missing_ok: true)?
      fs.remove(lock_path(root, entry.name), missing_ok: true)?
      removed += 1
    }
  }

  let temporary = fp"{store_layout(root)}/tmp"

  if fs.exists(temporary)? {
    for entry in fs.children(temporary)? {
      fs.remove(entry.path)?
    }
  }

  {artifacts: removed, kept: remaining}
}
