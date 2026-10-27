##! Publication of completed immutable BuildPlan artifacts.
use plan as build_plan
use proof as pm_proof
use remote
use repo_snapshot
use store
use types
use util

type RepoArtifactMetadataDto = {name: Str, ver: Str, rel: Str}

type RepoIndexMerge = {index: List[types.RemotePackage], already_published: Bool}

type RepoPublishStage = {publication: types.RepoPublication, entry: types.RemotePackage, metadata: Path}

proc repo_verify_node_receipt(value: types.BuildPlan, node: types.PlanNode, receipt: types.ArtifactReceipt) [error] {
  let dependency_keys = store.receipt_dependency_keys(node)
  let runtime_dependency_keys = store.receipt_runtime_dependency_keys(node)

  if receipt.key != node.artifact_key or receipt.target != value.target or receipt.package_name != node.name or receipt.package_id != node.package_id or receipt.recipe_sha256 != node.recipe_sha256 or receipt.dependency_keys != dependency_keys or receipt.runtime_dependency_keys != runtime_dependency_keys {
    return Err(
      types.PmError.PackageContract(f"artifact receipt {node.artifact_key} does not match BuildPlan node {node.package_id}"),
    )
  }

  if types.plan_action_is_build(node.action) {
    guard receipt.origin == types.artifact_origin_built() else {
      return Err(
        types.PmError.PackageContract(f"BuildPlan build node {node.package_id} is not a locally proved artifact"),
      )
    }
  } else if receipt.origin != types.artifact_origin_remote() {
    return Err(
      types.PmError.PackageContract(f"BuildPlan remote node {node.package_id} is not a verified imported artifact"),
    )
  }
}

proc repo_package_kind(receipt: types.ArtifactReceipt, node: types.PlanNode) -> Result[types.PackageKind] {
  let metadata = fp"{receipt.artifact_dir}/metadata.json"
  let raw = json.read(metadata)?.require(Record)?
  let core = raw.require(RepoArtifactMetadataDto)?

  if core.name != node.name or core.ver != node.ver or core.rel != node.rel {
    return Err(types.PmError.PackageContract(f"artifact metadata {metadata} does not match {node.package_id}"))
  }

  if "package_kind" in raw {
    return types.parse_package_kind(raw.get("package_kind")?.require()?)
  }

  types.package_payload()
}

proc repo_verified_proof_path(store_root: Path, node: types.PlanNode, receipt: types.ArtifactReceipt) -> Result[Path] {
  let primary = fp"{receipt.artifact_dir}/proof.json"

  return primary when receipt.origin == types.artifact_origin_remote()

  if receipt.proof_key == node.proof_key {
    pm_proof.verify_artifact_receipt(primary, node, receipt.payload_sha256)
    return primary
  }

  let reproved = store.reproof_receipt_path(store_root, node.artifact_key, node.proof_key)

  if ! reproved.exists() {
    return Err(
      types.PmError.PackageTarball(
        f"{node.package_id} is missing proof {node.proof_key}; execute the BuildPlan before publication",
      ),
    )
  }

  pm_proof.verify_artifact_receipt(reproved, node, receipt.payload_sha256)
  reproved
}

## Selects every BuildPlan node from verified immutable Store receipts without building or resolving a remote index.
export proc snapshot(value: types.BuildPlan, store_root: Path) [fs, error] -> Result[types.RepoSnapshot, Error] {
  build_plan.validate(value)
  var packages: List[types.RepoPublication] = []

  for node in value.nodes {
    let receipt = store.verify_artifact(store_root, node.artifact_key)?
    repo_verify_node_receipt(value, node, receipt)
    let kind = repo_package_kind(receipt, node)?
    let proof = repo_verified_proof_path(store_root, node, receipt)?
    packages += [
      {
        node,
        receipt,
        payload: fp"{receipt.artifact_dir}/payload.tar.gz",
        metadata: fp"{receipt.artifact_dir}/metadata.json",
        proof,
        kind,
      },
    ]
  }

  {format: "laputa-repo-snapshot-1", target: value.target, plan_sha256: value.plan_sha256, packages}
}

proc repo_metadata_for_publication(value: types.RepoPublication, arch: Str, output: Path) -> Result[Path] {
  let raw = json.read(value.metadata)?.require(RepoArtifactMetadataDto)?
  let metadata = fp"{output}/{value.node.artifact_key}.json"
  metadata.parent.mkdir()
  metadata.write_atomic(
    json.encode({
      ...raw,
      arch,
      target: types.target_text(value.receipt.target),
      artifact_key: value.node.artifact_key,
      recipe_sha256: value.node.recipe_sha256,
      executor_sha256: value.receipt.executor_sha256,
      proof_key: value.node.proof_key,
      proof_sha256: value.node.proof_sha256,
    })? + "\n",
  )
  metadata
}

proc repo_publication_entry(value: types.RepoPublication, arch: Str, metadata: Path) -> Result[types.RemotePackage] {
  let node = value.node
  let payload_rel = util.remote_binary_rel(arch, node.name, node.ver, node.rel, node.artifact_key)
  let metadata_rel = util.remote_metadata_rel(arch, node.name, node.ver, node.rel, node.artifact_key, node.proof_key)
  let proof_rel = util.remote_proof_rel(arch, node.name, node.ver, node.rel, node.artifact_key, node.proof_key)
  let metadata_sha256 = hash.sha256(metadata)?.hex()
  let proof_receipt_sha256 = hash.sha256(value.proof)?.hex()

  {
    arch,
    name: node.name,
    ver: node.ver,
    rel: node.rel,
    deps: [dependency.name for dependency in node.dependencies if dependency.kind == types.dependency_runtime()],
    runtime_only_deps: [
      dependency.name
      for dependency in node.dependencies
      if dependency.kind == types.dependency_runtime_only()
    ],
    mkdeps_host: [
      dependency.name
      for dependency in node.dependencies
      if dependency.kind == types.dependency_build_host()
    ],
    mkdeps_target: [
      dependency.name
      for dependency in node.dependencies
      if dependency.kind == types.dependency_build_target()
    ],
    sha256: if value.kind == types.package_meta() { "" } else { hash.sha256(value.payload)?.hex() },
    size: if value.kind == types.package_meta() { 0 } else { value.payload.metadata()?.size },
    tarball: if value.kind == types.package_meta() { "" } else { payload_rel.display() },
    metadata: metadata_rel.display(),
    metadata_sha256,
    artifact_key: node.artifact_key,
    recipe_sha256: node.recipe_sha256,
    executor_sha256: value.receipt.executor_sha256,
    proof_key: node.proof_key,
    proof_sha256: node.proof_sha256,
    proof: proof_rel.display(),
    proof_receipt_sha256,
    source_sha256: "",
    metapackage: value.kind == types.package_meta(),
  }
}

proc repo_same_publication(left: types.RemotePackage, right: types.RemotePackage) -> Bool {
  left.arch == right.arch and left.name == right.name and left.ver == right.ver and left.rel == right.rel and left.deps == right.deps and left.runtime_only_deps == right.runtime_only_deps and left.mkdeps_host == right.mkdeps_host and left.mkdeps_target == right.mkdeps_target and left.sha256 == right.sha256 and left.size == right.size and left.tarball == right.tarball and left.metadata == right.metadata and left.metadata_sha256 == right.metadata_sha256 and left.artifact_key == right.artifact_key and left.recipe_sha256 == right.recipe_sha256 and left.executor_sha256 == right.executor_sha256 and left.proof_key == right.proof_key and left.proof_sha256 == right.proof_sha256 and left.proof == right.proof and left.proof_receipt_sha256 == right.proof_receipt_sha256 and left.source_sha256 == right.source_sha256 and left.metapackage == right.metapackage
}

proc repo_merge_publication(
  index: List[types.RemotePackage],
  entry: types.RemotePackage,
) [error] -> Result[RepoIndexMerge] {
  var replaced = false

  let updated: List[types.RemotePackage] = collect {
    for existing in index {
      if existing.arch == entry.arch and existing.name == entry.name {
        return {index, already_published: true} when repo_same_publication(existing, entry)

        if build_plan.plan_compare_version_release(entry.ver, entry.rel, existing.ver, existing.rel) < 0 {
          return Err(
            types.PmError.PackageContract(
              f"{entry.arch}/{entry.name} {util.version_id(entry.ver, entry.rel)} is behind remote {util.version_id(existing.ver, existing.rel)}; bump PKGBUILD.xsh rel explicitly",
            ),
          )
        }

        yield entry
        replaced = true
      } else {
        yield existing
      }
    }

    yield entry unless replaced
  }

  {index: updated |> sort-by f"{.arch}\t{.name}", already_published: false}
}

proc repo_publish_immutable_object(repo_url: Str, rel: Path, source: Path, token: Str, work: Path) {
  let _ = remote.upload_immutable_repo_file(repo_url, rel, source, token, work)?
}

## Publishes a verified repository snapshot: immutable package objects first and the remote index last.
export proc publish(
  repo_snapshot: types.RepoSnapshot,
  remote_repo: Str,
  token: Str,
  work: Path,
) [fs, net, time, error] {
  let arch = types.pm_target_arch(repo_snapshot.target)

  if repo_snapshot.format != "laputa-repo-snapshot-1" or arch == "" {
    return Err(types.PmError.PackageContract("unsupported repository snapshot"))
  }

  if remote_repo == "" {
    return Err(types.PmError.RemoteRepo("repository publication needs a remote repository"))
  }

  if ! util.is_local_repo_url(remote_repo) and token.trim() == "" {
    return Err(
      types.PmError.Auth("repository publication needs LAPUTA_TOKEN for network remotes other than the local mirror"),
    )
  }

  work.mkdir()
  let stages: List[RepoPublishStage] = collect {
    for publication in repo_snapshot.packages {
      let verified = store.verify_receipt(publication.receipt)?

      if verified != publication.receipt {
        return Err(
          types.PmError.PackageContract(f"repository snapshot receipt changed for {publication.node.package_id}"),
        )
      }

      if publication.receipt.origin == types.artifact_origin_built() {
        pm_proof.verify_artifact_receipt(publication.proof, publication.node, verified.payload_sha256)
      }

      let metadata = repo_metadata_for_publication(publication, arch, fp"{work}/metadata")?
      yield {publication, entry: repo_publication_entry(publication, arch, metadata)?, metadata}
    }
  }

  var index = remote.load_remote_index_from_repo(remote_repo, fp"{work}/index")?
  let pending: List[RepoPublishStage] = collect {
    for stage in stages {
      let merged = repo_merge_publication(index, stage.entry)?
      index = merged.index

      if merged.already_published {
        print ${stage.entry.arch} ${stage.entry.name} util.version_id(stage.entry.ver, stage.entry.rel) \
          "already-published"
      } else {
        yield stage
      }
    }
  }

  for stage in pending {
    if ! stage.entry.metapackage {
      repo_publish_immutable_object(remote_repo, fp"{stage.entry.tarball}", stage.publication.payload, token, work)
    }

    repo_publish_immutable_object(remote_repo, fp"{stage.entry.metadata}", stage.metadata, token, work)
    repo_publish_immutable_object(remote_repo, fp"{stage.entry.proof}", stage.publication.proof, token, work)
  }

  if ! pending.is_empty() {
    remote.write_remote_index_to_repo(remote_repo, work, fp"{work}/index", index, token)
  }
}

## Publishes an offline-signed repository snapshot. The snapshot files are
## composed and signed outside PM (see docs/PM.md); this verifies the
## signature, binds the snapshot to the exact current remote index, requires
## a generation advance over any published snapshot, and uploads the metadata
## before the signature so the signature is the linearization point.
export proc publish_snapshot(
  remote_repo: Str,
  token: Str,
  work: Path,
  snapshot_dir: Path,
  keys: List[Bytes],
) [fs, net, time, error] {
  if remote_repo == "" {
    return Err(types.PmError.RemoteRepo("repository snapshot publication needs a remote repository"))
  }

  if ! util.is_local_repo_url(remote_repo) and token.trim() == "" {
    return Err(
      types.PmError.Auth("repository snapshot publication needs LAPUTA_TOKEN for network remotes other than the local mirror"),
    )
  }

  work.mkdir()
  let metadata_path = fp"{snapshot_dir}/snapshot.json"
  let signature_path = fp"{snapshot_dir}/snapshot.sig"

  guard metadata_path.exists() else {
    return Err(types.PmError.PackageContract(f"repository snapshot directory is missing snapshot.json: {snapshot_dir}"))
  }

  guard signature_path.exists() else {
    return Err(types.PmError.PackageContract(f"repository snapshot directory is missing snapshot.sig: {snapshot_dir}"))
  }

  let metadata = metadata_path.read_bytes()?
  let signature = signature_path.read_bytes()?
  let parsed = repo_snapshot.snapshot_parse_metadata(metadata)?
  repo_snapshot.snapshot_verify_signature(metadata, signature, keys)

  let index_work = fp"{work}/snapshot-index"
  index_work.mkdir()
  let index_dest = fp"{index_work}/index.json"
  let failure = remote.try_fetch_repo_file(remote_repo, p"index.json", index_dest)?

  guard failure == "" else {
    return Err(types.PmError.RemoteIndex(f"repository snapshot publication needs the published index: {failure}"))
  }

  let index_bytes = index_dest.read_bytes()?
  guard index_bytes.sha256().hex() == parsed.index_sha256 else {
    return Err(types.PmError.RemoteIndex("repository snapshot index digest does not match the published index; re-issue the snapshot after publication"))
  }

  let prior_dest = fp"{index_work}/prior-snapshot.json"
  let prior_failure = remote.try_fetch_repo_file(remote_repo, util.remote_snapshot_rel(), prior_dest)?

  if prior_failure == "" {
    let prior = repo_snapshot.snapshot_parse_metadata(prior_dest.read_bytes()?)?
    guard repo_snapshot.snapshot_u64_is_greater(parsed.generation, prior.generation) else {
      if parsed.generation == prior.generation and parsed.index_sha256 == prior.index_sha256 {
        print "snapshot" $parsed.generation "already-published"
        return
      }

      return Err(
        types.PmError.PackageContract(f"repository snapshot generation {parsed.generation} does not advance the published generation {prior.generation}"),
      )
    }
  }

  if util.is_file_url(remote_repo) {
    let metadata_dest = util.repo_file_path(remote_repo, util.remote_snapshot_rel())?
    let signature_dest = util.repo_file_path(remote_repo, util.remote_snapshot_signature_rel())?
    metadata_dest.parent.mkdir()
    atomically replace metadata_dest as temporary {
      metadata_path.copy(to: temporary, overwrite: true)
    }
    signature_dest.parent.mkdir()
    atomically replace signature_dest as temporary {
      signature_path.copy(to: temporary, overwrite: true)
    }
    return
  }

  remote.upload_repo_file(remote_repo, util.remote_snapshot_rel(), metadata_path, token, work)
  remote.upload_repo_file(remote_repo, util.remote_snapshot_signature_rel(), signature_path, token, work)
}
