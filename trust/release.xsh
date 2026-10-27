##! Verifies signed certificate releases for atomic trust activation.
use trust.policy

## Exact release inputs captured from the source and installed-policy snapshots.
export type SignedReleaseInput = {
  metadata: Bytes,
  signature: Bytes,
  provisioned_public_key: Bytes,
  root_bundle: Bytes,
  next_policy: Bytes,
  installed_policy_snapshot: Bytes,
  now_epoch_seconds: Int,
}

## Signed trust release validation failed.
export error ReleaseError = InvalidData(message: Str)

## A verified trust release: the exact bytes to activate.
## VerifiedTrustRelease.
export type VerifiedTrustRelease = {
  root_bundle: Bytes,
  trust_policy: Bytes,
}

type ReleaseMetadata = {
  generation: Str,
  expires_at: Int,
  root_bundle_sha256: Str,
  trust_policy_sha256: Str,
}

let MAX_METADATA_BYTES = 4096
let MAX_ROOT_BUNDLE_BYTES = 4194304
let MAX_RELEASE_VALIDITY_SECONDS = 7776000

pure release_fail(message: Str) -> Error {
  ReleaseError.InvalidData(message)
}

proc release_require(condition: Bool, message: Str) [error] {
  guard condition else {
    return Err(release_fail(message))
  }
}

pure release_sha256_is_valid(value: Str) -> Bool {
  value.byte_len() == 64 and value == value.lower() and value.delete("0123456789abcdef") == ""
}

## Parses one exact signed-release metadata document.
export proc release_parse_metadata(message: Bytes) [error] -> Result[ReleaseMetadata, Error] {
  release_require(! message.is_empty() and message.len() <= MAX_METADATA_BYTES, "signed metadata size is invalid")
  let text = message.utf8()?
  release_require(text.ends_with("\n") and "\r" not in text, "signed metadata must use LF-terminated UTF-8 lines")
  let lines = text.byte_slice(0, text.byte_len() - 1).split("\n")
  release_require(lines.len() == 5 and lines[0] == "laputa-trust-release-v1", "signed metadata header or field count is invalid")

  let generation_fields = lines[1].split(" ")
  release_require(
    generation_fields.len() == 2 and generation_fields[0] == "generation" and policy.policy_u64_text_is_valid(generation_fields[1]),
    "signed metadata generation is invalid",
  )

  let expiry_fields = lines[2].split(" ")
  release_require(expiry_fields.len() == 2 and expiry_fields[0] == "expires-at", "signed metadata expiry field is invalid")
  let expires_at = expiry_fields[1].parse_int_decimal()?
  release_require(expires_at > 0 and f"{expires_at}" == expiry_fields[1], "signed metadata expiry is invalid")

  let root_digest_fields = lines[3].split(" ")
  release_require(
    root_digest_fields.len() == 2 and root_digest_fields[0] == "root-bundle-sha256" and release_sha256_is_valid(root_digest_fields[1]),
    "signed metadata root bundle digest is invalid",
  )

  let policy_digest_fields = lines[4].split(" ")
  release_require(
    policy_digest_fields.len() == 2 and policy_digest_fields[0] == "trust-policy-sha256" and release_sha256_is_valid(policy_digest_fields[1]),
    "signed metadata trust policy digest is invalid",
  )

  {
    generation: generation_fields[1],
    expires_at,
    root_bundle_sha256: root_digest_fields[1],
    trust_policy_sha256: policy_digest_fields[1],
  }
}

## Verifies one signed release against the installed snapshot.
## release_verify.
export proc release_verify(input: SignedReleaseInput) [error] -> Result[VerifiedTrustRelease, Error] {
  release_require(input.provisioned_public_key.len() == 32, "a provisioned 32-byte Laputa trust public key is required")
  release_require(input.signature.len() == 64, "trust release signature must contain 64 raw Ed25519 bytes")
  release_require(! input.metadata.is_empty() and input.metadata.len() <= MAX_METADATA_BYTES, "signed metadata size is invalid")
  release_require(input.root_bundle.len() > 0 and input.root_bundle.len() <= MAX_ROOT_BUNDLE_BYTES, "root bundle size is invalid")

  let signature_valid = crypto.ed25519_verify(input.metadata, input.provisioned_public_key, input.signature)?
  release_require(signature_valid, "trust release metadata signature is invalid")

  let release = release_parse_metadata(input.metadata)?
  release_require(input.now_epoch_seconds >= 0, "current UTC time is invalid")
  release_require(release.expires_at > input.now_epoch_seconds, "trust release has expired")
  release_require(
    release.expires_at - input.now_epoch_seconds <= MAX_RELEASE_VALIDITY_SECONDS,
    "trust release expiry exceeds the 90-day validity limit",
  )

  let installed_policy = policy.parse(input.installed_policy_snapshot)?
  let next_policy = policy.parse(input.next_policy)?
  release_require(
    policy.policy_u64_is_greater(release.generation, installed_policy.generation),
    "trust release generation does not advance the installed policy",
  )
  release_require(next_policy.generation == release.generation, "trust policy generation does not match signed metadata")
  release_require(
    input.root_bundle.sha256().hex() == release.root_bundle_sha256,
    "root bundle digest does not match signed metadata",
  )
  release_require(
    input.next_policy.sha256().hex() == release.trust_policy_sha256,
    "trust policy digest does not match signed metadata",
  )
  net.validate_root_bundle(input.root_bundle)?

  {
    root_bundle: input.root_bundle,
    trust_policy: input.next_policy,
  }
}
