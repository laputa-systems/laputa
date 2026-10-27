##! Versioned signed repository snapshots binding the exact published index.
use pm.types

## A parsed repository snapshot: the exact index bytes clients may plan from.
export type RepoSnapshotMetadata = {generation: Str, expires_at: Int, index_sha256: Str}

## The exact inputs one snapshot verification consumes.
export type SnapshotVerifyInput = {
  metadata: Bytes,
  signature: Bytes,
  keys: List[Bytes],
  index_bytes: Bytes,
  accepted: SnapshotAccepted?,
  now_epoch_seconds: Int,
}

## The last snapshot a client accepted from one repository: the rollback floor
## and the lowest wall-clock time that verification has observed.
export type SnapshotAccepted = {generation: Str, index_sha256: Str, lower_bound: Int}

## A verified snapshot: the generation and index digest the caller may use.
export type VerifiedRepoSnapshot = {generation: Str, expires_at: Int, index_sha256: Str}

## Durable accepted-snapshot state for one repository.
export type SnapshotStatePaths = {accepted: Path}

let MAX_SNAPSHOT_METADATA_BYTES = 4096
let MAX_SNAPSHOT_SIGNATURE_BYTES = 64
let MAX_SNAPSHOT_INDEX_BYTES = 10485760
let MAX_SNAPSHOT_VALIDITY_SECONDS = 7776000

pure snapshot_fail(message: Str) -> Error {
  types.PmError.RemoteIndex(message)
}

proc snapshot_require(condition: Bool, message: Str) [error] {
  guard condition else {
    return Err(snapshot_fail(message))
  }
}

## Whether `value` is a canonical positive unsigned 64-bit decimal string.
export pure snapshot_u64_text_is_valid(value: Str) -> Bool {
  let length = value.byte_len()
  if length == 0 or length > 20 or value.starts_with("0") {
    return false
  }

  if value.delete("0123456789") != "" {
    return false
  }

  length < 20 or value <= "18446744073709551615"
}

## Whether canonical unsigned decimal `left` is greater than `right`.
export pure snapshot_u64_is_greater(left: Str, right: Str) -> Bool {
  left.byte_len() > right.byte_len() or (left.byte_len() == right.byte_len() and left > right)
}

pure snapshot_sha256_is_valid(value: Str) -> Bool {
  value.byte_len() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

## Renders the exact bytes an offline signing ceremony signs for one snapshot.
export pure snapshot_metadata_text(generation: Str, expires_at: Int, index_sha256: Str) -> Str {
  f"laputa-repo-snapshot-v1\ngeneration {generation}\nexpires-at {expires_at}\nindex-sha256 {index_sha256}\n"
}

## Parses one exact signed-snapshot metadata document.
export proc snapshot_parse_metadata(message: Bytes) [error] -> Result[RepoSnapshotMetadata, Error] {
  snapshot_require(! message.is_empty() and message.len() <= MAX_SNAPSHOT_METADATA_BYTES, "signed snapshot metadata size is invalid")
  let text = message.utf8()?
  snapshot_require(text.ends_with("\n") and "\r" not in text, "signed snapshot metadata must use LF-terminated UTF-8 lines")
  let lines = text.byte_slice(0, text.byte_len() - 1).split("\n")
  snapshot_require(lines.len() == 4 and lines[0] == "laputa-repo-snapshot-v1", "signed snapshot metadata header or field count is invalid")

  let generation_fields = lines[1].split(" ")
  snapshot_require(
    generation_fields.len() == 2 and generation_fields[0] == "generation" and snapshot_u64_text_is_valid(generation_fields[1]),
    "signed snapshot metadata generation is invalid",
  )

  let expiry_fields = lines[2].split(" ")
  snapshot_require(expiry_fields.len() == 2 and expiry_fields[0] == "expires-at", "signed snapshot metadata expiry field is invalid")
  let expires_at = match expiry_fields[1].parse_int_decimal() {
    Ok(found) => found,
    Err(_) => {
      return Err(snapshot_fail("signed snapshot metadata expiry is invalid"))
    },
  }
  snapshot_require(expires_at > 0 and f"{expires_at}" == expiry_fields[1], "signed snapshot metadata expiry is invalid")

  let digest_fields = lines[3].split(" ")
  snapshot_require(
    digest_fields.len() == 2 and digest_fields[0] == "index-sha256" and snapshot_sha256_is_valid(digest_fields[1]),
    "signed snapshot metadata index digest is invalid",
  )

  {
    generation: generation_fields[1],
    expires_at,
    index_sha256: digest_fields[1],
  }
}

## Verifies one detached snapshot signature against a provisioned key set.
## Any listed key may authorize the snapshot, so a rotation window accepts
## both the current and the next key; dropping a key revokes it.
export proc snapshot_verify_signature(metadata: Bytes, signature: Bytes, keys: List[Bytes]) [error] -> Result[Unit, Error] {
  snapshot_require(! keys.is_empty(), "no repository snapshot verification key is provisioned")
  snapshot_require(signature.len() == MAX_SNAPSHOT_SIGNATURE_BYTES, "repository snapshot signature must contain 64 raw Ed25519 bytes")

  for key in keys {
    snapshot_require(key.len() == 32, "a provisioned repository snapshot key must contain exactly 32 raw Ed25519 bytes")
  }

  for key in keys {
    if crypto.ed25519_verify(metadata, key, signature)? {
      return
    }
  }

  Err(snapshot_fail("repository snapshot metadata signature is invalid"))
}

## Verifies one snapshot against its exact index bytes and the accepted floor.
## Equal-generation replays are accepted only for identical index bytes, so a
## frozen publisher cannot mix new objects under a stale generation.
export proc snapshot_verify(input: SnapshotVerifyInput) [error] -> Result[VerifiedRepoSnapshot, Error] {
  snapshot_require(! input.metadata.is_empty() and input.metadata.len() <= MAX_SNAPSHOT_METADATA_BYTES, "signed snapshot metadata size is invalid")
  snapshot_require(! input.index_bytes.is_empty() and input.index_bytes.len() <= MAX_SNAPSHOT_INDEX_BYTES, "repository snapshot index size is invalid")
  snapshot_verify_signature(input.metadata, input.signature, input.keys)?

  let snapshot = snapshot_parse_metadata(input.metadata)?
  snapshot_require(input.now_epoch_seconds >= 0, "current UTC time is invalid")
  snapshot_require(snapshot.expires_at > input.now_epoch_seconds, "repository snapshot has expired")
  snapshot_require(
    snapshot.expires_at - input.now_epoch_seconds <= MAX_SNAPSHOT_VALIDITY_SECONDS,
    "repository snapshot expiry exceeds the 90-day validity limit",
  )
  snapshot_require(
    input.index_bytes.sha256().hex() == snapshot.index_sha256,
    "repository index digest does not match signed snapshot metadata",
  )

  let accepted_snapshot = input.accepted

  if accepted_snapshot != null {
    snapshot_require(input.now_epoch_seconds >= accepted_snapshot.lower_bound, "system clock reads behind the last observed repository snapshot time; refusing to validate expiry")
    snapshot_require(
      snapshot.index_sha256 == accepted_snapshot.index_sha256 or snapshot_u64_is_greater(snapshot.generation, accepted_snapshot.generation),
      "repository snapshot generation does not advance the accepted snapshot",
    )
    snapshot_require(
      snapshot.generation == accepted_snapshot.generation or snapshot_u64_is_greater(snapshot.generation, accepted_snapshot.generation),
      "repository snapshot generation rolls back the accepted snapshot",
    )
  }

  {generation: snapshot.generation, expires_at: snapshot.expires_at, index_sha256: snapshot.index_sha256}
}

## Loads provisioned snapshot keys: one file of concatenated raw 32-byte
## Ed25519 public keys. A multi-key file is a rotation window; removing a key
## revokes it. Snapshots themselves never carry keys.
export proc snapshot_load_keys(key_path: Path) [fs, error] -> Result[List[Bytes], Error] {
  guard key_path.exists()? else {
    return Err(
      snapshot_fail(f"no repository snapshot verification key is provisioned at {key_path.display()}; refusing to plan from a production repository"),
    )
  }

  let raw = key_path.read_bytes()?
  guard ! raw.is_empty() and raw.len() % 32 == 0 else {
    return Err(snapshot_fail("provisioned repository snapshot keys must be concatenated raw 32-byte Ed25519 public keys"))
  }

  raw.chunks(32)
}

## The durable accepted-snapshot state paths for one repository.
export pure snapshot_state_paths(state_dir: Path, repo: Str) -> SnapshotStatePaths {
  {accepted: fp"{state_dir}/accepted/{bytes.from_text(repo).sha256().hex()}.json"}
}

proc snapshot_accepted_from_record(raw: Record) [error] -> Result[SnapshotAccepted, Error] {
  let generation: Str = raw.get("generation")?.require()?
  let index_sha256: Str = raw.get("index_sha256")?.require()?
  let lower_bound: Int = raw.get("lower_bound")?.require()?

  {generation, index_sha256, lower_bound}
}

## Reads the accepted snapshot floor, or null when no snapshot was accepted yet.
export proc snapshot_read_accepted(paths: SnapshotStatePaths) [fs, error] -> Result[SnapshotAccepted?, Error] {
  guard paths.accepted.exists()? else {
    return null
  }

  let raw_value = match json.read(paths.accepted) {
    Ok(found) => found,
    Err(_) => {
      return Err(snapshot_fail("accepted repository snapshot state is corrupt; refusing to validate expiry"))
    },
  }

  let raw_record = match raw_value.require(Record) {
    Ok(found) => found,
    Err(_) => {
      return Err(snapshot_fail("accepted repository snapshot state is corrupt; refusing to validate expiry"))
    },
  }

  let decoded = match snapshot_accepted_from_record(raw_record) {
    Ok(found) => found,
    Err(_) => {
      return Err(snapshot_fail("accepted repository snapshot state is corrupt; refusing to validate expiry"))
    },
  }

  guard snapshot_u64_text_is_valid(decoded.generation) and snapshot_sha256_is_valid(decoded.index_sha256) and decoded.lower_bound >= 0 else {
    return Err(snapshot_fail("accepted repository snapshot state is corrupt; refusing to validate expiry"))
  }

  decoded
}

## Persists the accepted snapshot floor after successful verification.
export proc snapshot_persist_accepted(paths: SnapshotStatePaths, verified: VerifiedRepoSnapshot, now_epoch_seconds: Int) [fs, error] {
  var lower_bound = now_epoch_seconds
  let prior = snapshot_read_accepted(paths)?

  if prior != null {
    lower_bound = if now_epoch_seconds > prior.lower_bound { now_epoch_seconds } else { prior.lower_bound }
  }
  paths.accepted.parent.mkdir()
  json.write(paths.accepted, {generation: verified.generation, index_sha256: verified.index_sha256, lower_bound})
}
