##! Verifies and stages signed certificate releases into immutable system generations.
use pm.generation
use pm.types
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

## Existing build and store inputs plus separate candidate-generation and overlay paths.
export type TrustGenerationTarget = {
  build_plan: types.BuildPlan,
  runtime_roots: List[Str],
  store_root: Path,
  output_root: Path,
  overlay_root: Path,
}

## Signed trust release validation failed.
export error ReleaseError = InvalidData(message: Str)

type VerifiedTrustRelease = {
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
let RELEASE_REPLACEMENTS = ["etc/laputa/trust-policy", "etc/ssl/certs/ca-certificates.crt"]

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

proc release_parse_metadata(message: Bytes) [error] -> Result[ReleaseMetadata, Error] {
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

proc release_verify(input: SignedReleaseInput) [error] -> Result[VerifiedTrustRelease, Error] {
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

proc release_stage_overlay(overlay_root: Path, value: VerifiedTrustRelease) [fs, error] -> Result[types.GenerationProfile, Error] {
  let policy_path = fp"{overlay_root}/etc/laputa/trust-policy"
  let root_bundle_path = fp"{overlay_root}/etc/ssl/certs/ca-certificates.crt"
  policy_path.parent.mkdir(parents: true)
  root_bundle_path.parent.mkdir(parents: true)
  policy_path.write(value.trust_policy)
  policy_path.chmod(0o644)
  root_bundle_path.write(value.root_bundle)
  root_bundle_path.chmod(0o644)
  release_require(policy_path.read_bytes()? == value.trust_policy, "staged trust policy differs from the verified release")
  release_require(root_bundle_path.read_bytes()? == value.root_bundle, "staged root bundle differs from the verified release")

  json.write(
    fp"{overlay_root}/overlay.json",
    {format: "laputa-generation-overlay-1", profile: "trust-release", replacements: RELEASE_REPLACEMENTS},
  )
  let profile = generation.overlay_profile(overlay_root)?
  release_require(profile.name == "trust-release", "staged trust overlay profile is invalid")
  release_require(profile.replacements == RELEASE_REPLACEMENTS, "staged trust overlay replacements are invalid")
  release_require(
    hash.sha256(policy_path)?.hex() == value.trust_policy.sha256().hex(),
    "staged trust policy digest differs from the verified release",
  )
  release_require(
    hash.sha256(root_bundle_path)?.hex() == value.root_bundle.sha256().hex(),
    "staged root bundle digest differs from the verified release",
  )
  profile
}

proc release_require_separate_roots(output_root: Path, overlay_root: Path) [error] {
  guard output_root != overlay_root else {
    return Err(release_fail("generation output and trust overlay must be separate paths"))
  }

  let output_inside_overlay = match output_root.strip_prefix(overlay_root) {
    Ok(_) => true
    Err(_) => false
  }
  let overlay_inside_output = match overlay_root.strip_prefix(output_root) {
    Ok(_) => true
    Err(_) => false
  }
  guard ! output_inside_overlay and ! overlay_inside_output else {
    return Err(release_fail("generation output and trust overlay must not contain one another"))
  }
}

## Composes one signed release as a new immutable generation and leaves prior generations untouched.
export proc compose_signed_release(input: SignedReleaseInput, target: TrustGenerationTarget) [fs, error] -> Result[types.GenerationReceipt, Error] {
  let verified = release_verify(input)?
  release_require(! target.output_root.exists()?, "immutable generation output already exists")
  release_require_separate_roots(target.output_root, target.overlay_root)
  target.overlay_root.mkdir()
  defer target.overlay_root.remove()
  let profile = release_stage_overlay(target.overlay_root, verified)?
  let plan = generation.plan_profile(target.build_plan, target.runtime_roots, profile)?
  generation.compose(plan, target.store_root, target.output_root, target.overlay_root)
}
