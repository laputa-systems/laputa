##! Signed trust-release acquisition and atomic activation.

use trust.key as trust_key
use trust.policy as trust_policy
use trust.release as trust_release
use trust.store as trust_store

## Trust status, verification, or update failed without changing guarantees.
## TrustUpdateError.
export error TrustUpdateError = InvalidData(message: Str)

## Verified-size release bytes acquired from a directory or the network.
## TrustReleaseBytes.
export type TrustReleaseBytes = {metadata: Bytes, signature: Bytes, bundle: Bytes, policy: Bytes}
## Verified release bytes plus the digests activation binds.
## TrustVerifiedRelease.
export type TrustVerifiedRelease = {
  generation: Str,
  expires_at: Int,
  bundle: Bytes,
  policy: Bytes,
  bundle_sha256: Str,
  policy_sha256: Str,
}

const UPDATE_METADATA_MAX_BYTES = 8192
const UPDATE_SIGNATURE_MAX_BYTES = 256
const UPDATE_BUNDLE_MAX_BYTES = 4194304
const UPDATE_POLICY_MAX_BYTES = 1048576
const SOURCE_METADATA_MAX_BYTES = 4096
const SOURCE_SIGNATURE_MAX_BYTES = 64
const SOURCE_BUNDLE_MAX_BYTES = 4194304
const SOURCE_POLICY_MAX_BYTES = 1048576
const UPDATE_DOWNLOAD_TIMEOUT = 60s
const UPDATE_CONNECT_TIMEOUT = 10s

pure update_fail(message: Str) -> Error {
  TrustUpdateError.InvalidData(message)
}

proc trust_effective_now_seconds(paths: trust_store.TrustStorePaths) [fs, time, error] -> Result[Int, Error] {
  let wall = time.now() / 1000
  let floor = trust_store.trust_store_read_lower_bound(paths)?
  guard floor <= 0 or wall >= floor else {
    return Err(
      update_fail(
        "system clock reads behind the last observed trust time; refusing to validate expiry (possible snapshot rollback)",
      ),
    )
  }

  if wall > floor {
    wall
  } else {
    floor
  }
}

proc trust_read_source_file(dir: Path, name: Str, max_bytes: Int) [fs, error] -> Result[Bytes, Error] {
  let target = fp"{dir}/{name}"
  guard target.exists()? else {
    return Err(update_fail(f"release directory is missing {name}"))
  }

  let meta = target.metadata()?
  guard meta.kind == "file" and ! target.is_symlink()? else {
    return Err(update_fail(f"release file is not a regular file: {name}"))
  }

  guard meta.size <= max_bytes else {
    return Err(update_fail(f"release file exceeds its size bound: {name}"))
  }

  target.read_bytes()
}

proc trust_read_source_dir(dir: Path) [fs, error] -> Result[TrustReleaseBytes, Error] {
  guard dir.exists()? else {
    return Err(update_fail(f"release directory does not exist: {dir.display()}"))
  }

  guard dir.metadata()?.kind == "dir" else {
    return Err(update_fail(f"release source is not a directory: {dir.display()}"))
  }

  {
    metadata: trust_read_source_file(dir, trust_store.RELEASE_METADATA_NAME, SOURCE_METADATA_MAX_BYTES)?,
    signature: trust_read_source_file(dir, trust_store.RELEASE_SIGNATURE_NAME, SOURCE_SIGNATURE_MAX_BYTES)?,
    bundle: trust_read_source_file(dir, trust_store.RELEASE_BUNDLE_NAME, SOURCE_BUNDLE_MAX_BYTES)?,
    policy: trust_read_source_file(dir, trust_store.RELEASE_POLICY_NAME, SOURCE_POLICY_MAX_BYTES)?,
  }
}

proc trust_acquire_from_url(base_url: Str, work: Path) [fs, net, error] -> Result[TrustReleaseBytes, Error] {
  guard base_url.starts_with("https://") else {
    return Err(update_fail("trust release URL must use https://"))
  }

  var base = base_url
  while base.ends_with("/") {
    base = base.byte_slice(0, base.byte_len() - 1)
  }

  let files = [
    {name: trust_store.RELEASE_METADATA_NAME, bound: UPDATE_METADATA_MAX_BYTES},
    {name: trust_store.RELEASE_SIGNATURE_NAME, bound: UPDATE_SIGNATURE_MAX_BYTES},
    {name: trust_store.RELEASE_BUNDLE_NAME, bound: UPDATE_BUNDLE_MAX_BYTES},
    {name: trust_store.RELEASE_POLICY_NAME, bound: UPDATE_POLICY_MAX_BYTES},
  ]
  var metadata = bytes.from_text("")
  var signature = bytes.from_text("")
  var bundle = bytes.from_text("")
  var policy = bytes.from_text("")
  for file in files {
    if file.name == trust_store.RELEASE_METADATA_NAME {
      metadata = trust_download_one(base, work, file.name, file.bound)?
    } else if file.name == trust_store.RELEASE_SIGNATURE_NAME {
      signature = trust_download_one(base, work, file.name, file.bound)?
    } else if file.name == trust_store.RELEASE_BUNDLE_NAME {
      bundle = trust_download_one(base, work, file.name, file.bound)?
    } else {
      policy = trust_download_one(base, work, file.name, file.bound)?
    }
  }

  {metadata, signature, bundle, policy}
}

proc trust_verify_candidate(
  paths: trust_store.TrustStorePaths,
  key: Bytes,
  release: TrustReleaseBytes,
  now_epoch_seconds: Int,
) [fs, error] -> Result[TrustVerifiedRelease, Error] {
  let snapshot = trust_store.canonical_policy_path(paths.root).read_bytes()?
  let verified = trust_release.release_verify({
    metadata: release.metadata,
    signature: release.signature,
    provisioned_public_key: key,
    root_bundle: release.bundle,
    next_policy: release.policy,
    installed_policy_snapshot: snapshot,
    now_epoch_seconds,
  })?
  let parsed = trust_release.release_parse_metadata(release.metadata)?
  {
    generation: parsed.generation,
    expires_at: parsed.expires_at,
    bundle: verified.root_bundle,
    policy: verified.trust_policy,
    bundle_sha256: verified.root_bundle.sha256().hex(),
    policy_sha256: verified.trust_policy.sha256().hex(),
  }
}

proc trust_verify_active_release(
  paths: trust_store.TrustStorePaths,
  key: Bytes,
  generation: Str,
  now_epoch_seconds: Int,
) [fs, error] -> Result[TrustVerifiedRelease, Error] {
  let verified = trust_verify_committed_bookkeeping(paths, key, generation)?
  guard verified.expires_at > now_epoch_seconds else {
    return Err(update_fail(f"active trust release has expired: generation {generation}"))
  }

  verified
}

proc trust_verify_committed_bookkeeping(
  paths: trust_store.TrustStorePaths,
  key: Bytes,
  generation: Str,
) [fs, error] -> Result[TrustVerifiedRelease, Error] {
  let dir = trust_store.trust_store_generation_dir(paths, generation)
  let metadata = fp"{dir}/{trust_store.TRUST_METADATA_NAME}".read_bytes()?
  let signature = fp"{dir}/{trust_store.TRUST_SIGNATURE_NAME}".read_bytes()?
  let bundle = fp"{dir}/{trust_store.TRUST_BUNDLE_NAME}".read_bytes()?
  let policy = fp"{dir}/{trust_store.TRUST_POLICY_NAME}".read_bytes()?
  guard signature.len() == 64 else {
    return Err(update_fail(f"active trust release signature is invalid: generation {generation}"))
  }

  guard crypto.ed25519_verify(metadata, key, signature)? else {
    return Err(update_fail(f"active trust release signature does not verify: generation {generation}"))
  }

  let parsed = trust_release.release_parse_metadata(metadata)?
  guard parsed.generation == generation else {
    return Err(update_fail(f"active trust metadata names the wrong generation: {generation}"))
  }

  guard bundle.sha256().hex() == parsed.root_bundle_sha256 else {
    return Err(update_fail(f"active trust bundle digest mismatch: generation {generation}"))
  }

  guard policy.sha256().hex() == parsed.trust_policy_sha256 else {
    return Err(update_fail(f"active trust policy digest mismatch: generation {generation}"))
  }

  let installed = trust_policy.parse(policy)?
  guard installed.generation == generation else {
    return Err(update_fail(f"active trust policy names the wrong generation: {generation}"))
  }

  {
    generation,
    expires_at: parsed.expires_at,
    bundle,
    policy,
    bundle_sha256: parsed.root_bundle_sha256,
    policy_sha256: parsed.trust_policy_sha256,
  }
}

## Reports the installed trust state without changing it.
export proc trust_status(system_root: Path) [fs, time, error] -> Result[Record, Error] {
  let paths = trust_store.trust_store_paths(system_root)
  guard trust_store.trust_store_has_store(paths)? else {
    print "trust status: uninitialized (no trust store; run trust update to bootstrap)"
    return {initialized: false}
  }

  let active = trust_store.trust_store_read_active(paths)?
  let bundle_path = trust_store.canonical_bundle_path(paths.root)
  let policy_path = trust_store.canonical_policy_path(paths.root)
  let bundle = bundle_path.read_bytes()?
  let policy = policy_path.read_bytes()?
  let parsed_policy = trust_policy.parse(policy)?
  let key_status = match trust_key.trust_key_load(paths.root) {
    Ok(key) => f"present sha256:{trust_key.trust_key_fingerprint(key)}",
    Err(_) => "MISSING (updates will fail closed)",
  }
  let accepted = trust_store.trust_store_read_accepted(paths)?
  let journal = trust_store.trust_store_read_journal(paths)?
  let pending = if journal.present { f"{journal.phase} generation {journal.generation}" } else { "none" }
  var debris = ""
  if trust_store.trust_store_has_store(paths)? and paths.staging.exists()? {
    for entry in fs.children(paths.staging)? {
      let owned = journal.present and journal.staging != "" and entry.path.display() == fp"{paths.store}/{journal.staging}".display()
      if ! owned {
        debris = if debris == "" { entry.name } else { f"{debris} {entry.name}" }
      }
    }
  }

  let atomic = trust_store.trust_store_probe_atomic(paths)?
  let active_dir = trust_store.trust_store_generation_dir(paths, active)
  let active_meta_path = fp"{active_dir}/{trust_store.TRUST_METADATA_NAME}"
  let provenance = if active_meta_path.exists()? { "signed-release" } else { "package-seed" }
  if provenance == "package-seed" {
    let owner_path = fp"{active_dir}/{trust_store.TRUST_OWNER_NAME}"
    guard owner_path.exists()? and owner_path.read_text()? == "package-seed\n" else {
      return Err(
        update_fail(
          f"generation {active} has no signed release and no seed provenance; the store is incomplete",
        ),
      )
    }
  }

  let now = time.now() / 1000
  var freshness = "seed (no signed expiry; apply a signed release)"
  var expires_at = 0
  if provenance == "signed-release" {
    let active_parsed = trust_release.release_parse_metadata(active_meta_path.read_bytes()?)?
    expires_at = active_parsed.expires_at
    freshness = if active_parsed.expires_at > now {
      f"current (expires {active_parsed.expires_at})"
    } else {
      "EXPIRED"
    }
  }

  let activated_at = fs.stat(paths.active, follow_symlinks: false)?.mtime_ns / 1000000000

  print f"trust status: generation {active}"
  print f"  root bundle: sha256:{bundle.sha256().hex()}"
  print f"  trust policy: sha256:{policy.sha256().hex()} generation {parsed_policy.generation}"
  print f"  verification key: {key_status}"
  print f"  last activation: {activated_at}"
  print f"  accepted generation: {accepted}"
  print f"  pending: {pending}"
  print f"  staging debris: {debris}"
  print f"  provenance: {provenance}"
  print f"  freshness: {freshness}"
  print f"  atomic activation: {atomic}"

  {
    initialized: true,
    generation: active,
    bundle_sha256: bundle.sha256().hex(),
    policy_sha256: policy.sha256().hex(),
    policy_generation: parsed_policy.generation,
    accepted,
    pending,
    debris,
    provenance,
    freshness,
    expires_at,
    atomic_capable: atomic,
    activated_at,
  }
}

## Verifies a release directory without changing installed state.
export proc trust_verify(system_root: Path, source: Path) [fs, time, error] -> Result[Record, Error] {
  let key = trust_key.trust_key_load(system_root)?
  let paths = trust_store.trust_store_paths(system_root)
  let release = trust_read_source_dir(source)?
  let now = trust_effective_now_seconds(paths)?
  let verified = trust_verify_candidate(paths, key, release, now)?

  print f"trust verify: release generation {verified.generation} is valid"
  print f"  expires at: {verified.expires_at}"
  print f"  root bundle: sha256:{verified.bundle_sha256}"
  print f"  trust policy: sha256:{verified.policy_sha256}"
  verified
}

## Updates from an offline release directory. Works without networking and
## without a working WebPKI trust store.
export proc trust_update_from_dir(
  system_root: Path,
  source: Path,
) [fs, process, time, error] -> Result[Record, Error] {
  let release = trust_read_source_dir(source)?
  let paths = trust_store.trust_store_paths(system_root)
  let now = trust_effective_now_seconds(paths)?
  trust_apply_release(system_root, release, now)?
}

## Updates from a release published over HTTPS. Transport only; the detached
## signature over pinned key material authorizes the release.
export proc trust_update_from_url(
  system_root: Path,
  base_url: Str,
) [fs, process, time, net, error] -> Result[Record, Error] {
  let work = fs.tempdir()?
  let work_path = work.host_path()?
  let release = trust_acquire_from_url(base_url, work_path)?
  let paths = trust_store.trust_store_paths(system_root)
  let now = trust_effective_now_seconds(paths)?
  trust_apply_release(system_root, release, now)?
}

proc trust_download_one(
  base_url: Str,
  work: Path,
  name: Str,
  bound: Int,
) [fs, net, error] -> Result[Bytes, Error] {
  let dest = fp"{work}/{name}"
  let result = net.download({
    url: f"{base_url}/{name}",
    dest,
    atomic: true,
    overwrite: true,
    fail_status: true,
    max_body_bytes: bound,
    connect_timeout: UPDATE_CONNECT_TIMEOUT,
    timeout: UPDATE_DOWNLOAD_TIMEOUT,
  })?
  guard result.effective_url.starts_with("https://") else {
    return Err(update_fail(f"trust release fetch left https: {name}"))
  }

  dest.read_bytes()
}

proc trust_recover(
  paths: trust_store.TrustStorePaths,
  key: Bytes,
  now_epoch_seconds: Int,
) [fs, time, error] -> Result[Record, Error] {
  let journal = trust_store.trust_store_read_journal(paths)?
  guard journal.present else {
    return Ok({recovered: false, phase: "clean"})
  }

  guard journal.phase != "unknown" else {
    return Err(
      update_fail(
        "trust journal is unreadable; refusing automatic recovery (inspect and remove it manually after verifying active state)",
      ),
    )
  }

  if journal.phase == "locked" or journal.phase == "staged" {
    trust_store.trust_store_remove_owned_staging(paths, journal.staging, journal.token)?
    trust_store.trust_store_clear_journal(paths)?
    return Ok({recovered: true, phase: journal.phase})
  }

  guard journal.phase == "committed" or journal.phase == "activated" or journal.phase == "persisted" else {
    return Err(update_fail(f"trust journal names an unknown phase: {journal.phase}"))
  }

  guard trust_policy.policy_u64_text_is_valid(journal.generation) else {
    return Err(update_fail("trust journal names an invalid generation; refusing automatic recovery"))
  }

  if journal.phase == "committed" {
    let committed = trust_store.trust_store_generation_dir(paths, journal.generation)
    let staged_path = fp"{paths.store}/{journal.staging}"
    if committed.exists()? and staged_path.exists()? {
      return Err(
        update_fail(
          "staging and a committed generation both exist; refusing automatic recovery (inspect and remove one manually)",
        ),
      )
    }

    if ! committed.exists()? {
      guard journal.staging != "" and staged_path.exists()? else {
        return Err(update_fail("trust journal names a committed generation with no staged or committed bytes; refusing automatic recovery"))
      }

      trust_store.trust_store_commit_generation(paths, journal.staging, journal.generation)?
    }

    let verified = trust_verify_active_release(paths, key, journal.generation, now_epoch_seconds)?
    trust_store.trust_store_remove_owned_staging(paths, journal.staging, journal.token)?
    trust_store.trust_store_flip_active(paths, journal.generation)?
    trust_store.trust_store_persist_accepted(paths, journal.generation)?
    trust_store.trust_store_clear_journal(paths)?
    return Ok({recovered: true, phase: journal.phase, generation: verified.generation})
  }

  let active = trust_store.trust_store_read_active(paths)?
  guard active == journal.generation else {
    return Err(
      update_fail(
        f"trust journal generation {journal.generation} disagrees with active generation {active}; refusing automatic recovery",
      ),
    )
  }

  let verified = trust_verify_active_release(paths, key, active, now_epoch_seconds)?
  trust_store.trust_store_persist_accepted(paths, active)?
  trust_store.trust_store_clear_journal(paths)?
  Ok({recovered: true, phase: journal.phase, generation: verified.generation})
}

proc trust_reconcile_accepted(
  paths: trust_store.TrustStorePaths,
  key: Bytes,
  now_epoch_seconds: Int,
) [fs, time, error] -> Result[Str, Error] {
  let active = trust_store.trust_store_read_active(paths)?
  let accepted = trust_store.trust_store_read_accepted(paths)?
  guard trust_policy.policy_u64_is_greater(active, accepted) else {
    guard ! trust_policy.policy_u64_is_greater(accepted, active) else {
      return Err(
        update_fail(
          f"accepted generation {accepted} is ahead of active generation {active}; refusing to proceed",
        ),
      )
    }

    return accepted
  }

  let _ = trust_verify_active_release(paths, key, active, now_epoch_seconds)?
  trust_store.trust_store_persist_accepted(paths, active)?
  active
}

proc trust_activate_release(
  paths: trust_store.TrustStorePaths,
  verified: TrustVerifiedRelease,
  metadata: Bytes,
  signature: Bytes,
  now_epoch_seconds: Int,
) [fs, process, time, error] -> Result[Record, Error] {
  let generation = verified.generation
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    generation,
    verified.bundle,
    verified.policy,
    metadata,
    signature,
  )?
  trust_store.trust_store_write_journal(paths, "staged", generation, staged.path, staged.token)?

  match trust_store.trust_store_commit_generation(paths, staged.path, generation) {
    Ok(_) => {},
    Err(_) => {
      let committed_metadata = match fp"{trust_store.trust_store_generation_dir(paths, generation)}/{trust_store.TRUST_METADATA_NAME}".read_bytes() {
        Ok(found) => found,
        Err(_) => bytes.from_text(""),
      }
      guard committed_metadata == metadata and committed_metadata.len() > 0 else {
        return Err(
          update_fail(f"immutable trust generation already exists and does not match the verified release: {generation}"),
        )
      }

      let _ = trust_store.trust_store_verify_generation(paths, generation, verified.bundle_sha256, verified.policy_sha256)?
      print f"trust update: adopting identical committed generation {generation}"
    },
  }

  trust_store.trust_store_write_journal(paths, "committed", generation, staged.path, staged.token)?

  trust_store.trust_store_flip_active(paths, generation)?
  trust_store.trust_store_write_journal(paths, "activated", generation, "", staged.token)?

  trust_store.trust_store_persist_accepted(paths, generation)?
  trust_store.trust_store_persist_lower_bound(paths, now_epoch_seconds)?
  trust_store.trust_store_write_journal(paths, "persisted", generation, "", staged.token)?

  let effective = trust_store.trust_store_reobserve(
    paths,
    generation,
    verified.bundle_sha256,
    verified.policy_sha256,
  )?
  trust_store.trust_store_remove_owned_staging(paths, staged.path, staged.token)?
  trust_store.trust_store_clear_journal(paths)?

  print f"trust update: activated generation {generation}"
  print f"  root bundle: sha256:{effective.bundle_sha256}"
  print f"  trust policy: sha256:{effective.policy_sha256}"
  effective
}

proc trust_resume_active_release(
  paths: trust_store.TrustStorePaths,
  key: Bytes,
  release: TrustReleaseBytes,
  now_epoch_seconds: Int,
) [fs, time, error] -> Result[Record, Error] {
  let active = trust_store.trust_store_read_active(paths)?
  let parsed = trust_release.release_parse_metadata(release.metadata)?
  guard parsed.generation == active else {
    return Err(update_fail("active generation changed during re-application; aborting"))
  }

  let verified = trust_verify_active_release(paths, key, active, now_epoch_seconds)?
  let committed_metadata = fp"{trust_store.trust_store_generation_dir(paths, active)}/{trust_store.TRUST_METADATA_NAME}".read_bytes()?
  guard release.metadata == committed_metadata else {
    return Err(update_fail(f"conflicting release for active generation {active}; refusing to apply"))
  }

  guard verified.bundle_sha256 == release.bundle.sha256().hex() else {
    return Err(update_fail(f"conflicting root bundle for active generation {active}; refusing to apply"))
  }

  guard verified.policy_sha256 == release.policy.sha256().hex() else {
    return Err(update_fail(f"conflicting trust policy for active generation {active}; refusing to apply"))
  }

  trust_store.trust_store_persist_accepted(paths, active)?
  trust_store.trust_store_persist_lower_bound(paths, now_epoch_seconds)?
  let effective = trust_store.trust_store_reobserve(
    paths,
    active,
    verified.bundle_sha256,
    verified.policy_sha256,
  )?

  print f"trust update: generation {active} is already active; re-observed canonical trust"
  print f"  root bundle: sha256:{effective.bundle_sha256}"
  print f"  trust policy: sha256:{effective.policy_sha256}"
  effective
}

proc trust_repair_active_pointer(
  paths: trust_store.TrustStorePaths,
  key: Bytes,
) [fs, error] -> Result[Str, Error] {
  let accepted = match trust_store.trust_store_read_accepted(paths) {
    Ok(found) => found,
    Err(_) => {
      return Err(
        update_fail(
          "installed trust state is incomplete and the accepted generation is unreadable; refusing to bootstrap over it",
        ),
      )
    },
  }
  let dir = trust_store.trust_store_generation_dir(paths, accepted)
  guard dir.exists()? else {
    return Err(
      update_fail(
        f"installed trust state is incomplete and accepted generation {accepted} is absent; refusing to bootstrap over it",
      ),
    )
  }

  let metadata_path = fp"{dir}/{trust_store.TRUST_METADATA_NAME}"
  if metadata_path.exists()? {
    let _ = trust_verify_committed_bookkeeping(paths, key, accepted)?
  } else {
    let owner_path = fp"{dir}/{trust_store.TRUST_OWNER_NAME}"
    guard owner_path.exists()? and owner_path.read_text()? == "package-seed\n" else {
      return Err(
        update_fail(
          f"accepted generation {accepted} has no signed release and no seed provenance; refusing to repair it",
        ),
      )
    }

    let policy = fp"{dir}/{trust_store.TRUST_POLICY_NAME}".read_bytes()?
    let parsed_policy = trust_policy.parse(policy)?
    guard parsed_policy.generation == accepted else {
      return Err(
        update_fail(f"accepted seed generation {accepted} names the wrong generation; refusing to repair it"),
      )
    }

    net.validate_root_bundle(fp"{dir}/{trust_store.TRUST_BUNDLE_NAME}".read_bytes()?)?
  }

  trust_store.trust_store_flip_active(paths, accepted)?
  print f"trust update: repaired lost active pointer at accepted generation {accepted}"
  accepted
}

proc trust_apply_release(
  system_root: Path,
  release: TrustReleaseBytes,
  now_epoch_seconds: Int,
) [fs, process, time, error] -> Result[Record, Error] {
  let key = trust_key.trust_key_load(system_root)?
  let paths = trust_store.trust_store_paths(system_root)
  let lock = trust_store.trust_store_take_lock(paths)?
  defer fs.unlock(lock)

  let _ = trust_recover(paths, key, now_epoch_seconds)?

  match trust_store.trust_store_read_active(paths) {
    Ok(_) => {},
    Err(_) => {
      let repairable = match trust_store.trust_store_read_accepted(paths) {
        Ok(accepted) => {
          trust_store.trust_store_generation_dir(paths, accepted).exists()?
        },
        Err(_) => false,
      }
      if repairable {
        let _ = trust_repair_active_pointer(paths, key)?
      } else {
        let bootstrapped = trust_store.trust_store_bootstrap_from_seeds(system_root)?
        print f"trust update: bootstrapped generation {bootstrapped} from package seeds"
      }
    },
  }

  let accepted = trust_reconcile_accepted(paths, key, now_epoch_seconds)?
  let parsed = trust_release.release_parse_metadata(release.metadata)?
  let active = trust_store.trust_store_read_active(paths)?
  if parsed.generation == accepted and parsed.generation == active {
    return trust_resume_active_release(paths, key, release, now_epoch_seconds)
  }

  guard trust_policy.policy_u64_is_greater(parsed.generation, accepted) else {
    return Err(
      update_fail(
        f"release generation {parsed.generation} does not advance accepted generation {accepted}",
      ),
    )
  }

  let verified = trust_verify_candidate(paths, key, release, now_epoch_seconds)?
  trust_activate_release(paths, verified, release.metadata, release.signature, now_epoch_seconds)?
}
