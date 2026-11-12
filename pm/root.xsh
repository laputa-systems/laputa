##! Deterministic immutable root plans composed only from verified artifact-store receipts.
use confined
use store as artifact_store
use types
use util

const manual_directory = "usr/share/man"

type ArtifactEntryDto = {path: Str, kind: Str, mode: Int, sha256: Str, target: Str}

type ArtifactMetadataDto = {name: Str, ver: Str, rel: Str, files: List[ArtifactEntryDto]}

type LegacyPackageDbMetadataDto = {
  name: Str,
  ver: Str,
  rel: Str,
  deps: List[Str],
  mkdeps_host: List[Str],
  mkdeps_target: List[Str],
  filetree: List[Record],
  nostrip: Bool,
  dir: Str,
  extract_install: Bool,
}

type LegacyPackageDbFile = {entry: types.ArtifactEntry, body: Bytes}

type RootArtifactDto = {package_name: Str, package_id: Str, artifact_key: Str, payload: Bool}

type RootEntryDto = {
  package_name: Str,
  package_id: Str,
  artifact_key: Str,
  path: Str,
  kind: Str,
  mode: Int,
  sha256: Str,
  target: Str,
}

type RootReceiptDto = {
  format: Str,
  target: Str,
  artifacts: List[RootArtifactDto],
  entries: List[RootEntryDto],
  generated_entries: List[ArtifactEntryDto],
  root_sha256: Str,
}

type DecodedArtifactMetadata = {kind: types.PackageKind, entries: List[types.ArtifactEntry]}

type RootOwnership = {plan: types.RootPlan, artifact_entries: Map[List[types.RootEntry]]}

pure root_sha256_text_is_valid(value: Str) -> Bool {
  value.count_chars() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

proc root_require_sha256(value: Str, label: Str) [error] {
  guard root_sha256_text_is_valid(value) else {
    return Err(types.PmError.PackageContract(f"{label} must be a lowercase SHA-256 digest"))
  }
}

proc root_require_relative_path(value: Str, label: Str) {
  if value == "" or value == "." {
    return Err(types.PmError.PackageContract(f"{label} must not be empty"))
  }

  let normalized = util.ensure_relative_path(fp"{value}", label)?

  if normalized.display() != value {
    return Err(types.PmError.PackageContract(f"{label} must be canonical and relative: {value}"))
  }
}

proc root_validate_symlink_target(path_value: Str, target: Str) [error] {
  if target == "" or target.starts_with("/") {
    return Err(types.PmError.PackageContract(f"symlink {path_value} has an invalid target {target}"))
  }

  var depth = path_value.split("/").len() - 1

  for component in target.split("/") {
    if component == "" {
      return Err(types.PmError.PackageContract(f"symlink {path_value} has an invalid target {target}"))
    }

    continue when component == "."

    if component == ".." {
      if depth == 0 {
        return Err(types.PmError.PackageContract(f"symlink {path_value} escapes the root: {target}"))
      }

      depth -= 1
    } else {
      depth += 1
    }
  }
}

proc root_decode_metadata_entry(value: ArtifactEntryDto) -> Result[types.ArtifactEntry] {
  {
    path: value.path,
    kind: types.parse_file_kind(value.kind)?,
    mode: value.mode,
    sha256: value.sha256,
    target: value.target,
  }
}

proc root_validate_metadata_entry(value: types.ArtifactEntry) {
  root_require_relative_path(value.path, "artifact metadata path")

  if value.path == "var/lib/laputa/root.json" or value.path == "usr/share/man/mandoc.db" {
    return Err(types.PmError.PackageContract(f"artifact metadata may not own generated root path {value.path}"))
  }

  if value.mode < 0 or value.mode > 0o7777 {
    return Err(types.PmError.PackageContract(f"artifact metadata mode for {value.path} is invalid"))
  }

  if value.kind == types.file_kind_file() or value.kind == types.file_kind_binary() {
    guard value.target == "" else {
      return Err(types.PmError.PackageContract(f"file {value.path} must not have a symlink target"))
    }

    root_require_sha256(value.sha256, f"file {value.path} SHA-256")
  } else if value.kind == types.file_kind_tree() {
    if value.sha256 != "" or value.target != "" {
      return Err(types.PmError.PackageContract(f"directory {value.path} must not have a hash or target"))
    }
  } else if value.kind == types.file_kind_symlink() {
    guard value.mode == 0o777 else {
      return Err(types.PmError.PackageContract(f"symlink {value.path} must have mode 0777"))
    }

    if value.sha256 != "" {
      return Err(types.PmError.PackageContract(f"symlink {value.path} must not have a file hash"))
    }

    root_validate_symlink_target(value.path, value.target)
  }
}

pure root_legacy_package_db_path(receipt: types.ArtifactReceipt, name: Str) -> Path {
  fp"var/lib/xsh-pm/packages/{receipt.package_name}/{name}"
}

proc root_legacy_package_db_file(
  extracted: Path,
  receipt: types.ArtifactReceipt,
  name: Str,
) -> Result[LegacyPackageDbFile] {
  let rel: RelPath = root_legacy_package_db_path(receipt, name).require()?
  let root_handle = fs.open_root(extracted)?

  match root_handle.readlink(rel) {
    Ok(_) => return Err(types.PmError.PackageContract(f"legacy package database {rel} must be a regular file"))
    Err(_) => {}
  }

  let metadata = root_handle.metadata(rel)?

  if metadata.kind != "file" or metadata.mode % 4096 != 0o644 {
    return Err(types.PmError.PackageContract(f"legacy package database {rel} must be mode 0644 regular file"))
  }

  let body = root_handle.read_bytes(rel)?
  {
    entry: {path: rel.display(), kind: types.file_kind_file(), mode: 0o644, sha256: body.sha256().hex(), target: ""},
    body,
  }
}

proc root_legacy_package_db_entries(
  receipt: types.ArtifactReceipt,
  sidecar: Record,
  dto: ArtifactMetadataDto,
  payload_entries: List[types.ArtifactEntry],
) -> Result[List[types.ArtifactEntry]] {
  let sandbox = fs.tempdir()?
  let extracted = fp"{sandbox.host_path()?}/payload"
  archive.extract(fp"{receipt.artifact_dir}/payload.tar.gz", extracted, .Tar, modes: .Exact)
  let manifest_file = root_legacy_package_db_file(extracted, receipt, "manifest.json")?
  let etcsums_file = root_legacy_package_db_file(extracted, receipt, "etcsums.json")?
  let metadata_file = root_legacy_package_db_file(extracted, receipt, "metadata.json")?
  let sidecar_manifest = sidecar.get("manifest")?.require(List[Str])?
  let stored_manifest = json.decode(manifest_file.body as Str)?.require(List[Str])?
  let expected_manifest = [entry.path for entry in payload_entries]

  if sidecar_manifest != expected_manifest or stored_manifest != sidecar_manifest {
    return Err(
      types.PmError.PackageContract(
        f"legacy package database manifest for {receipt.package_name} does not match sidecar inventory",
      ),
    )
  }

  let stored_etcsums = json.decode(etcsums_file.body as Str)?.require(List[types.EtcSum])?
  var expected_etcsums: List[types.EtcSum] = [
    {path: entry.path, sha256: entry.sha256}
    for entry in payload_entries
    if util.is_etc_file(fp"{entry.path}") and (entry.kind == types.file_kind_file() or entry.kind == types.file_kind_binary())
  ]
  if stored_etcsums != expected_etcsums {
    return Err(
      types.PmError.PackageContract(
        f"legacy package database etcsums for {receipt.package_name} do not match sidecar payload hashes",
      ),
    )
  }

  let stored_metadata = json.decode(metadata_file.body as Str)?.require(LegacyPackageDbMetadataDto)?
  let sidecar_deps = sidecar.get("deps")?.require(List[Str])?
  let sidecar_mkdeps_host = sidecar.get("mkdeps_host")?.require(List[Str])?
  let sidecar_mkdeps_target = sidecar.get("mkdeps_target")?.require(List[Str])?
  let sidecar_filetree = sidecar.get("filetree")?.require(List[Record])?

  if stored_metadata.name != dto.name or stored_metadata.ver != dto.ver or stored_metadata.rel != dto.rel or stored_metadata.deps != sidecar_deps or stored_metadata.mkdeps_host != sidecar_mkdeps_host or stored_metadata.mkdeps_target != sidecar_mkdeps_target or stored_metadata.filetree != sidecar_filetree or stored_metadata.nostrip or ! stored_metadata.extract_install or stored_metadata.dir == "" {
    return Err(
      types.PmError.PackageContract(
        f"legacy package database metadata for {receipt.package_name} does not match sidecar semantics",
      ),
    )
  }

  [manifest_file.entry, etcsums_file.entry, metadata_file.entry]
}

proc root_artifact_metadata(receipt: types.ArtifactReceipt) -> Result[DecodedArtifactMetadata] {
  let raw = json.read(fp"{receipt.artifact_dir}/metadata.json")?.require(Record)?
  let dto = raw.require(ArtifactMetadataDto)?
  let expected_id = util.package_id(dto.name, dto.ver, dto.rel)

  if dto.name != receipt.package_name or expected_id != receipt.package_id {
    return Err(types.PmError.PackageContract(f"artifact metadata does not match receipt {receipt.package_id}"))
  }

  var kind = types.package_payload()

  if "package_kind" in raw {
    let kind_text = raw.get("package_kind")?.require(Str)?
    kind = types.parse_package_kind(kind_text)?
  }

  var entries: List[types.ArtifactEntry] = []
  var seen: Set[Str] = set.empty()

  for raw_entry in dto.files {
    let entry = root_decode_metadata_entry(raw_entry)?
    root_validate_metadata_entry(entry)

    if entry.path in seen {
      return Err(types.PmError.PackageContract(f"artifact metadata repeats {entry.path} for {receipt.package_name}"))
    }

    seen = seen.add(entry.path)
    entries += [entry]
  }

  if ! ("package_kind" in raw) {
    for entry in root_legacy_package_db_entries(receipt, raw, dto, entries)? {
      if entry.path in seen {
        return Err(
          types.PmError.PackageContract(
            f"legacy package database entry {entry.path} duplicates sidecar metadata for {receipt.package_name}",
          ),
        )
      }

      seen = seen.add(entry.path)
      entries += [entry]
    }
  }

  if kind == types.package_meta() and ! entries.is_empty() {
    return Err(types.PmError.PackageContract(f"metapackage {receipt.package_name} must have no payload entries"))
  }

  {kind, entries: entries |> sort-by .path}
}

proc root_verify_entry_in(root_handle: FsRoot, entry: types.ArtifactEntry) {
  let rel = confined.rel(entry.path)?

  if entry.kind == types.file_kind_symlink() {
    let target = root_handle.readlink(rel)?

    if target.display() != entry.target {
      return Err(types.PmError.PackageContract(f"root symlink {entry.path} does not match metadata"))
    }

    return
  }

  if ! root_handle.exists(rel) {
    return Err(types.PmError.PackageContract(f"root entry {entry.path} is absent or unreadable"))
  }

  let meta = root_handle.metadata(rel)?

  if entry.kind == types.file_kind_file() or entry.kind == types.file_kind_binary() {
    guard meta.mode % 4096 == entry.mode else {
      return Err(types.PmError.PackageContract(f"root entry {entry.path} mode does not match metadata"))
    }

    if meta.kind != "file" or root_handle.read_bytes(rel)?.sha256().hex() != entry.sha256 {
      return Err(types.PmError.PackageContract(f"root file {entry.path} does not match metadata"))
    }
  } else if entry.kind == types.file_kind_tree() {
    if meta.kind != "dir" or meta.mode % 4096 != entry.mode {
      return Err(types.PmError.PackageContract(f"root directory {entry.path} does not match metadata"))
    }
  }
}

pure root_same_directory_metadata(left: types.RootEntry, right: types.RootEntry) -> Bool {
  left.kind == types.file_kind_tree()
    and right.kind == types.file_kind_tree()
    and left.mode == right.mode
    and left.sha256 == right.sha256
    and left.target == right.target
}

proc root_extract_payload(sandbox: FsRoot, receipt: types.ArtifactReceipt) {
  sandbox.extract(
    fp"{receipt.artifact_dir}/payload.tar.gz",
    p"payload",
    .Tar,
    links: .Contained,
    special: .Refuse,
    modes: .Exact,
  )
}

proc root_verify_payload_entries(receipt: types.ArtifactReceipt, entries: List[types.RootEntry]) {
  let sandbox = fs.tempdir()?
  root_extract_payload(sandbox, receipt)
  let extracted = fp"{sandbox.host_path()?}/payload"
  let payload = sandbox.open_root(p"payload")?
  var expected: Set[Str] = set.empty()

  for entry in entries {
    expected = expected.add(entry.path)
    match root_verify_entry_in(payload, entry) {
      Ok(_) => {}
      Err(problem) => return Err(
        types.PmError.PackageContract(
          f"artifact {receipt.package_name} payload entry {entry.path} failed verification: {problem.message}",
        ),
      )
    }
  }

  for actual in fs.walk(extracted) {
    let rel = actual.path.strip_prefix(extracted)?
    var owned = actual.kind == "file" or actual.kind == "symlink"

    if actual.kind == "dir" and rel != "." {
      var empty = true

      for _ in fs.children(actual.path)? {
        empty = false
        break
      }

      owned = empty
    }

    if owned and ! (rel.display() in expected) {
      return Err(types.PmError.PackageContract(f"artifact {receipt.package_name} payload contains undeclared {rel}"))
    }
  }
}

proc root_verified_artifacts(artifacts: List[types.ArtifactReceipt]) -> Result[List[types.ArtifactReceipt]] {
  root_checked_artifacts([artifact_store.verify_receipt(artifact)? for artifact in artifacts])
}

proc root_checked_artifacts(artifacts: List[types.ArtifactReceipt]) [error] -> Result[List[types.ArtifactReceipt]] {
  var keys: Set[Str] = set.empty()
  var names: Set[Str] = set.empty()

  let verified: List[types.ArtifactReceipt] = collect {
    for receipt in artifacts {
      if receipt.key in keys {
        return Err(types.PmError.PackageContract(f"duplicate artifact key {receipt.key}"))
      }

      if receipt.package_name in names {
        return Err(types.PmError.PackageContract(f"duplicate package {receipt.package_name} in root artifacts"))
      }

      keys = keys.add(receipt.key)
      names = names.add(receipt.package_name)
      yield receipt
    }
  }

  for receipt in verified {
    for dependency_key in receipt.runtime_dependency_keys {
      guard dependency_key in keys else {
        return Err(
          types.PmError.MissingDependency(f"{receipt.package_name} runtime dependency artifact {dependency_key} is absent"),
        )
      }
    }
  }

  verified |> sort-by .package_name
}

pure root_digest(target: types.Target, artifacts: List[types.RootArtifact], entries: List[types.RootEntry]) -> Str {
  var lines = [f"target\t{types.target_text(target)}"]

  for artifact in artifacts {
    lines += [
      f"artifact\t{artifact.package_name}\t{artifact.package_id}\t{artifact.artifact_key}\t{if artifact.payload { "payload" } else { "meta" }}",
    ]
  }

  for entry in entries {
    lines += [
      f"entry\t{entry.package_name}\t{entry.package_id}\t{entry.artifact_key}\t{entry.path}\t{types.file_kind_text(entry.kind)}\t{entry.mode}\t{entry.sha256}\t{entry.target}",
    ]
  }

  bytes.from_text(lines.join("\n") + "\n").sha256().hex()
}

proc root_validate_plan(value: types.RootPlan) [error] {
  guard value.format == "laputa-root-plan-1" else {
    return Err(types.PmError.PackageContract(f"unsupported root plan format {value.format}"))
  }

  if types.pm_target_arch(value.target) == "" {
    return Err(types.PmError.PackageContract("root plan has an unsupported target"))
  }

  var artifacts = value.artifacts
  var entries = value.entries
  artifacts = artifacts |> sort-by .package_name
  entries = entries |> sort-by .path

  if artifacts != value.artifacts or entries != value.entries {
    return Err(types.PmError.PackageContract("root plan is not in canonical order"))
  }

  if value.root_sha256 != root_digest(value.target, value.artifacts, value.entries) {
    return Err(types.PmError.PackageContract("root plan digest does not match"))
  }
}

pure root_artifact_dto(value: types.RootArtifact) -> RootArtifactDto {
  {
    package_name: value.package_name,
    package_id: value.package_id,
    artifact_key: value.artifact_key,
    payload: value.payload,
  }
}

pure root_entry_dto(value: types.RootEntry) -> RootEntryDto {
  {
    package_name: value.package_name,
    package_id: value.package_id,
    artifact_key: value.artifact_key,
    path: value.path,
    kind: types.file_kind_text(value.kind),
    mode: value.mode,
    sha256: value.sha256,
    target: value.target,
  }
}

proc root_artifact_from_dto(value: RootArtifactDto) [error] -> Result[types.RootArtifact] {
  {
    package_name: value.package_name,
    package_id: value.package_id,
    artifact_key: value.artifact_key,
    payload: value.payload,
  }
}

proc root_entry_from_dto(value: RootEntryDto) -> Result[types.RootEntry] {
  {
    package_name: value.package_name,
    package_id: value.package_id,
    artifact_key: value.artifact_key,
    path: value.path,
    kind: types.parse_file_kind(value.kind)?,
    mode: value.mode,
    sha256: value.sha256,
    target: value.target,
  }
}

pure root_receipt_dto(value: types.RootReceipt) -> RootReceiptDto {
  {
    format: value.format,
    target: types.target_text(value.target),
    artifacts: [root_artifact_dto(artifact) for artifact in value.artifacts],
    entries: [root_entry_dto(entry) for entry in value.entries],
    generated_entries: [{path: entry.path, kind: types.file_kind_text(entry.kind), mode: entry.mode, sha256: entry.sha256, target: entry.target} for entry in value.generated_entries],
    root_sha256: value.root_sha256,
  }
}

proc root_receipt_from_dto(value: RootReceiptDto) -> Result[types.RootReceipt] {
  var artifacts: List[types.RootArtifact] = []
  var entries: List[types.RootEntry] = []

  for artifact in value.artifacts {
    artifacts += [root_artifact_from_dto(artifact)?]
  }

  for entry in value.entries {
    entries += [root_entry_from_dto(entry)?]
  }

  {format: value.format, target: types.parse_target(value.target)?, artifacts, entries, generated_entries: [root_decode_metadata_entry(entry)? for entry in value.generated_entries], root_sha256: value.root_sha256}
}

proc root_validate_receipt(value: types.RootReceipt) {
  let plan: types.RootPlan = types.RootPlan(
    format: "laputa-root-plan-1",
    target: value.target,
    artifacts: value.artifacts,
    entries: value.entries,
    root_sha256: root_digest(value.target, value.artifacts, value.entries),
  )

  if value.format != "laputa-root-2" {
    return Err(types.PmError.PackageContract(f"unsupported root receipt format {value.format}"))
  }

  root_validate_plan(plan)
  if value.generated_entries.len() > 1 {
    return Err(types.PmError.PackageContract("root receipt repeats generated manual index"))
  }
  for entry in value.generated_entries {
    if entry.path != "usr/share/man/mandoc.db" or entry.kind != types.file_kind_file() or entry.mode != 0o644 or entry.target != "" {
      return Err(types.PmError.PackageContract("root receipt has invalid generated manual index metadata"))
    }
    root_require_sha256(entry.sha256, "manual index SHA-256")
  }
  if value.root_sha256 != root_completed_digest(plan, value.generated_entries) {
    return Err(types.PmError.PackageContract("root receipt digest does not match generated contents"))
  }
}

pure root_completed_digest(plan: types.RootPlan, generated: List[types.ArtifactEntry]) -> Str {
  return plan.root_sha256 when generated.is_empty()
  let lines = [f"generated\t{entry.path}\t{types.file_kind_text(entry.kind)}\t{entry.mode}\t{entry.sha256}\t{entry.target}" for entry in generated]
  bytes.from_text(plan.root_sha256 + "\n" + lines.join("\n") + "\n").sha256().hex()
}

proc root_receipt_for_plan(value: types.RootPlan) -> Result[types.RootReceipt] {
  root_validate_plan(value)
  {
    format: "laputa-root-2",
    target: value.target,
    artifacts: value.artifacts,
    entries: value.entries,
    generated_entries: [],
    root_sha256: value.root_sha256,
  }
}

## Creates the missing parent directories of `path_value` beneath `output` without following symlinks.
export proc root_ensure_parent(output: FsRoot, path_value: Str) [fs, error] {
  let parent = fp"{path_value}".parent.display()
  return when parent == "" or parent == "."
  confined.ensure_dir(output, parent)
}

proc root_materialize_entry(source: FsRoot, output: FsRoot, entry: types.RootEntry) {
  let rel = confined.rel(entry.path)?
  root_ensure_parent(output, entry.path)

  if entry.kind == types.file_kind_tree() {
    confined.ensure_dir(output, entry.path)
    output.chmod(rel, entry.mode)
    root_verify_entry_in(output, entry)
    return
  }

  let created = if entry.kind == types.file_kind_file() or entry.kind == types.file_kind_binary() {
    fs.root_install_file(source, rel, output, rel, entry.mode)
  } else {
    output.symlink(target: fp"{entry.target}", path: rel)
  }

  match created {
    Ok(_) => {}
    Err(problem) => return Err(
      types.PmError.PackageConflict(
        f"root path {entry.path} cannot be created while applying {entry.package_name}: {problem.message}",
      ),
    )
  }

  root_verify_entry_in(output, entry)
}

proc root_materialize_artifact(output: FsRoot, receipt: types.ArtifactReceipt, entries: List[types.RootEntry]) {
  let sandbox = fs.tempdir()?
  root_extract_payload(sandbox, receipt)
  let source = sandbox.open_root(p"payload")?

  for entry in entries {
    root_materialize_entry(source, output, entry)
  }
}

proc root_read_receipt_in(output: FsRoot) -> Result[types.RootReceipt] {
  let raw = json.decode(output.read_text(p"var/lib/laputa/root.json")?)?.require(Record)?
  if raw.get("format")?.require(Str)? != "laputa-root-2" {
    return Err(types.PmError.PackageContract("unsupported root receipt format; recompose the root"))
  }
  let dto = raw.require(RootReceiptDto)?
  let value = root_receipt_from_dto(dto)?
  root_validate_receipt(value)
  value
}

proc root_ownership(target: types.Target, verified: List[types.ArtifactReceipt]) -> Result[RootOwnership] {
  if types.pm_target_arch(target) == "" {
    return Err(types.PmError.PackageContract("root preflight target is unsupported"))
  }

  var artifact_entries_by_key: Map[List[types.RootEntry]] = {}
  var planned_artifacts: List[types.RootArtifact] = []
  var entries: List[types.RootEntry] = []
  var owners: Map[types.RootEntry] = {}
  var first_descendants: Map[types.RootEntry] = {}

  for receipt in verified {
    guard receipt.target == target else {
      return Err(
        types.PmError.PackageContract(f"artifact {receipt.package_name} target does not match {types.target_text(target)}"),
      )
    }

    let metadata = root_artifact_metadata(receipt)?
    let payload = metadata.kind != types.package_meta()
    planned_artifacts += [
      {
        package_name: receipt.package_name,
        package_id: receipt.package_id,
        artifact_key: receipt.key,
        payload,
      },
    ]
    var artifact_entries: List[types.RootEntry] = []

    for entry in metadata.entries {
      let planned: types.RootEntry = types.RootEntry(
        package_name: receipt.package_name,
        package_id: receipt.package_id,
        artifact_key: receipt.key,
        ...entry,
      )

      var coalesced = false

      if planned.path in owners {
        let owner = owners.get(planned.path)?
        if root_same_directory_metadata(owner, planned) {
          coalesced = true
        } else {
          if owner.kind == types.file_kind_tree() and planned.kind == types.file_kind_tree() {
            return Err(
              types.PmError.PackageConflict(
                f"root directory {planned.path} has incompatible metadata from {owner.package_name} and {receipt.package_name}",
              ),
            )
          }

          return Err(
            types.PmError.PackageConflict(
              f"root path {planned.path} is owned by both {owner.package_name} and {receipt.package_name}",
            ),
          )
        }
      }

      if ! coalesced {
        let components = planned.path.split("/")
        var prefix = ""
        var index = 0

        while index + 1 < components.len() {
          prefix = if prefix == "" { components[index] } else { f"{prefix}/{components[index]}" }

          if prefix in owners {
            let owner = owners.get(prefix)?
            if owner.kind != types.file_kind_tree() {
              return Err(
                types.PmError.PackageConflict(
                  f"root non-directory {owner.path} owned by {owner.package_name} conflicts with {planned.path}",
                ),
              )
            }
          }

          index += 1
        }

        if planned.kind != types.file_kind_tree() and planned.path in first_descendants {
          let owner = first_descendants.get(planned.path)?
          return Err(
            types.PmError.PackageConflict(
              f"root non-directory {planned.path} conflicts with {owner.path} owned by {owner.package_name}",
            ),
          )
        }

        entries += [planned]
        owners[planned.path] = planned
        prefix = ""
        index = 0

        while index + 1 < components.len() {
          prefix = if prefix == "" { components[index] } else { f"{prefix}/{components[index]}" }
          if ! (prefix in first_descendants) {
            first_descendants[prefix] = planned
          }

          index += 1
        }
      }

      artifact_entries += [planned]
    }

    artifact_entries_by_key[receipt.key] = artifact_entries
  }

  let ordered_artifacts = planned_artifacts |> sort-by .package_name
  let ordered_entries = entries |> sort-by .path
  let value: types.RootPlan = types.RootPlan(
    format: "laputa-root-plan-1",
    target:,
    artifacts: ordered_artifacts,
    entries: ordered_entries,
    root_sha256: root_digest(target, ordered_artifacts, ordered_entries),
  )
  root_validate_plan(value)
  {plan: value, artifact_entries: artifact_entries_by_key}
}

## Builds and verifies the complete ownership, runtime closure, metadata, and payload contract before root mutation.
export proc preflight(
  target: types.Target,
  artifacts: List[types.ArtifactReceipt],
) [fs, error] -> Result[types.RootPlan, Error] {
  let verified = root_verified_artifacts(artifacts)?
  let ownership = root_ownership(target, verified)?

  for artifact in ownership.plan.artifacts {
    if artifact.payload {
      for receipt in verified {
        if receipt.key == artifact.artifact_key {
          root_verify_payload_entries(receipt, ownership.artifact_entries.get(receipt.key)?)
        }
      }
    }
  }

  ownership.plan
}

## Plans path ownership and runtime-closure completeness for receipts whose objects the
## caller already trusts, such as Store lookups inside one build. Unlike `preflight`, it
## neither re-hashes Store objects nor compares payload contents with their metadata.
export proc trusted_preflight(
  target: types.Target,
  artifacts: List[types.ArtifactReceipt],
) [fs, error] -> Result[types.RootPlan, Error] {
  root_ownership(target, root_checked_artifacts(artifacts)?)?.plan
}

## Materializes verified artifacts into the empty unpublished directory `output` and writes its root receipt.
## The caller owns `output`'s staging and publication.
export proc root_compose_into(
  output: FsRoot,
  plan: types.RootPlan,
  artifacts: List[types.ArtifactReceipt],
) [fs, error] -> Result[types.RootReceipt, Error] {
  let verified = root_checked_artifacts(artifacts)?
  var by_key: Map[types.ArtifactReceipt] = {artifact.key: artifact for artifact in verified}

  for artifact in plan.artifacts {
    if artifact.payload {
      let entries = [entry for entry in plan.entries if entry.artifact_key == artifact.artifact_key]
      root_materialize_artifact(output, by_key.get(artifact.artifact_key)?, entries)
    }
  }

  let receipt = root_receipt_for_plan(plan)?
  root_write_receipt_in(output, receipt)
  root_verify_in(output, receipt)
  receipt
}

proc root_write_receipt_in(output: FsRoot, receipt: types.RootReceipt) {
  confined.ensure_dir(output, "var/lib/laputa")
  output.write_atomic(p"var/lib/laputa/root.json", json.encode(root_receipt_dto(receipt))? + "\n", replace: "regular_or_absent")
}

## Composes package artifacts into a verified root plan. The explicit `compose_artifacts` spelling
## avoids XSH's shared-module export collision with the public `generation.compose` boundary.
export proc compose_artifacts(
  output: Path,
  plan: types.RootPlan,
  artifacts: List[types.ArtifactReceipt],
) [fs, error] -> Result[types.RootReceipt, Error] {
  let expected = preflight(plan.target, artifacts)?

  if expected != plan {
    return Err(types.PmError.PackageContract("root plan does not match verified artifacts"))
  }

  if output.exists() {
    return Err(types.PmError.PackageConflict(f"immutable root {output} already exists"))
  }

  output.parent.mkdir()
  let publication = fs.open_root(output.parent)?
  let publication_mode = 0o777.clear_bits(fs.umask()?)
  let staging_rel = confined.create_staging(publication, "", output.name)?
  let staging = publication.open_root(confined.rel(staging_rel)?)?
  let receipt = root_compose_into(staging, plan, artifacts) ?? { |problem| return Err(confined.discard(publication, staging_rel, staging, problem)) }
  confined.publish(publication, staging_rel, staging, output.name, publication_mode)
  receipt
}

proc root_verify_in(output: FsRoot, receipt: types.RootReceipt) {
  root_validate_receipt(receipt)
  let stored = root_read_receipt_in(output)?

  if stored != receipt {
    return Err(types.PmError.PackageContract("root receipt does not match the completed root"))
  }

  for entry in receipt.entries {
    root_verify_entry_in(output, entry)
  }
  for entry in receipt.generated_entries {
    root_verify_entry_in(output, entry)
  }
}

## Verifies the durable root receipt and every installed payload entry without consulting mutable package state.
export proc verify(output: Path, receipt: types.RootReceipt) [fs, error] {
  root_verify_in(fs.open_root(output)?, receipt)
}

proc root_has_manual_pages(output: FsRoot) -> Result[Bool] {
  var pending = [manual_directory]

  while ! pending.is_empty() {
    let directory = pending[0]
    pending = pending |> drop(1)
    let listing = output.children(confined.rel(directory)?)?

    guard listing.state == "complete" else {
      return Err(types.PmError.PackageContract(f"cannot enumerate manual directory {directory}"))
    }

    for child in listing.children {
      let relative = child.display()

      if output.stat(confined.rel(relative)?)?.kind == "dir" {
        pending += [relative]
        continue
      }

      let beneath_manuals = fp"{relative}".strip_prefix(fp"{manual_directory}")?.display()
      return true when beneath_manuals.starts_with("man") and "/" in beneath_manuals
    }
  }

  false
}

proc root_require_regular_file(output: FsRoot, relative: Str, label: Str) {
  let target = confined.rel(relative)?

  match output.stat(target, follow_symlinks: true) {
    Ok(found) => guard found.kind == "file" else {
      return Err(types.PmError.PackageContract(f"manual index requires selected-root {label} {relative}"))
    }
    Err(problem) => return Err(
      types.PmError.PackageContract(f"manual index requires selected-root {label} {relative}: {problem.message}"),
    )
  }
}

proc root_require_index_tool_closure(output: FsRoot, arch: Str) {
  root_require_regular_file(output, f"usr/lib/ld-musl-{arch}.so.1", "tool or library")
  root_require_regular_file(output, "usr/bin/makewhatis", "tool or library")
  root_require_regular_file(output, "usr/lib/libz.so.1", "tool or library")
  let scratch = fs.tempdir()?
  var libraries = ["usr/bin/makewhatis"]
  var checked: Set[Str] = set.empty()
  var copies = 0

  while ! libraries.is_empty() {
    let library = libraries[0]
    libraries = libraries |> drop(1)
    continue when library in checked
    checked = checked.add(library)
    copies += 1
    let copy = f"library-{copies}"
    fs.root_install_file(output, confined.rel(library)?, scratch, confined.rel(copy)?, 0o600)
    let needed_libraries = elf.inspect(fp"{scratch.host_path()?}/{copy}")?.needed

    for needed in needed_libraries {
      continue when needed == "libc.so" or needed == f"libc.musl-{arch}.so.1"
      let dependency = f"usr/lib/{needed}"

      if "/" in needed {
        return Err(types.PmError.PackageContract(f"manual index requires selected-root library {needed}"))
      }

      root_require_regular_file(output, dependency, "library")
      libraries += [dependency]
    }
  }
}

## Generates a manual index in an unpublished staging root and records its generated contents.
## Every read and mutation goes through `output`; the index tool is its `makewhatis` opened
## beneath `output`. Kernel confinement restricts child filesystem opens to that retained root
## and writes to its retained manual directory, including the loader's host-path opens.
export proc root_index_manual_pages(output: FsRoot, receipt: types.RootReceipt) [fs, process, error] -> Result[types.RootReceipt, Error] {
  root_validate_receipt(receipt)
  if root_read_receipt_in(output)? != receipt {
    return Err(types.PmError.PackageContract("manual index root receipt does not match"))
  }
  let mandoc = [artifact for artifact in receipt.artifacts if artifact.package_name == "mandoc" and artifact.payload]
  return receipt when mandoc.is_empty()
  return receipt unless output.exists(confined.rel(manual_directory)?)
  return receipt unless root_has_manual_pages(output)
  let arch = types.pm_target_arch(receipt.target)
  root_require_index_tool_closure(output, arch)
  let host = output.host_path()?
  let manpath = fp"{host}/{manual_directory}"
  let loader = fp"{host}/usr/lib/ld-musl-{arch}.so.1"
  let program = fp"{host}/usr/bin/makewhatis"
  let library_path = fp"{host}/usr/lib"
  let manuals = output.open_root(confined.rel(manual_directory)?)?
  let database: RelPath = p"usr/share/man/mandoc.db"
  if output.exists(database) {
    if receipt.generated_entries.is_empty() {
      return Err(types.PmError.PackageConflict("manual index path is already owned"))
    }
    output.remove(database)
  }
  let command = output.command(confined.rel(f"usr/lib/ld-musl-{arch}.so.1")?, [loader, "--library-path", library_path, program, manpath], env: {LD_PRELOAD: "", LD_LIBRARY_PATH: "", LC_ALL: "C"})?
  let status = linux.run_confined(command, read: [output], write: [manuals])?
  if ! status.ok {
    return Err(types.PmError.PackageContract("selected-root makewhatis failed; generation was not published"))
  }
  output.chmod(database, 0o644)
  let generated: List[types.ArtifactEntry] = [{path: "usr/share/man/mandoc.db", kind: types.file_kind_file(), mode: 0o644, sha256: output.read_bytes(database)?.sha256().hex(), target: ""}]
  let plan: types.RootPlan = {format: "laputa-root-plan-1", target: receipt.target, artifacts: receipt.artifacts, entries: receipt.entries, root_sha256: root_digest(receipt.target, receipt.artifacts, receipt.entries)}
  let completed: types.RootReceipt = {...receipt, generated_entries: generated, root_sha256: root_completed_digest(plan, generated)}
  root_validate_receipt(completed)
  output.write_atomic(p"var/lib/laputa/root.json", json.encode(root_receipt_dto(completed))? + "\n")
  completed
}

## Verifies generated root contents against the root identity embedded in a generation receipt.
export proc root_verify_generated_contents(output: Path, expected_sha256: Str) [fs, error] {
  let handle = fs.open_root(output)?
  let receipt = root_read_receipt_in(handle)?
  if receipt.root_sha256 != expected_sha256 {
    return Err(types.PmError.PackageContract("generation root identity does not match its root receipt"))
  }
  for entry in receipt.generated_entries {
    root_verify_entry_in(handle, entry)
  }
}
