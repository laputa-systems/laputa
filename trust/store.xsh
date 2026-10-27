##! Versioned operating-system trust store: layout, locking, and atomic activation.

use trust.policy as trust_policy

## Trust store layout or activation failed in a way callers must not ignore.
## TrustStoreError.
export error TrustStoreError = InvalidData(message: Str)

## Resolved store locations below one system root.
## TrustStorePaths.
export type TrustStorePaths = {
  root: Path,
  store: Path,
  generations: Path,
  staging: Path,
  active: Path,
  accepted: Path,
  lower_bound: Path,
  journal: Path,
  lock_file: Path,
}

## Generation and file names inside the store.
## TRUST_GENERATIONS_DIR.
export const TRUST_GENERATIONS_DIR = "generations"
## TRUST_STAGING_DIR.
export const TRUST_STAGING_DIR = "staging"
## TRUST_ACTIVE_NAME.
export const TRUST_ACTIVE_NAME = "active"
## TRUST_ACTIVE_SCRATCH_NAME.
export const TRUST_ACTIVE_SCRATCH_NAME = "active.new"
## TRUST_ACCEPTED_NAME.
export const TRUST_ACCEPTED_NAME = "accepted"
## TRUST_LOWER_BOUND_NAME.
export const TRUST_LOWER_BOUND_NAME = "time-lower-bound"
## TRUST_JOURNAL_NAME.
export const TRUST_JOURNAL_NAME = "journal.json"
## TRUST_LOCK_NAME.
export const TRUST_LOCK_NAME = "update.lock"
## TRUST_BUNDLE_NAME.
export const TRUST_BUNDLE_NAME = "ca-certificates.crt"
## TRUST_POLICY_NAME.
export const TRUST_POLICY_NAME = "trust-policy"
## TRUST_METADATA_NAME.
export const TRUST_METADATA_NAME = "metadata"
## TRUST_SIGNATURE_NAME.
export const TRUST_SIGNATURE_NAME = "metadata.sig"
## TRUST_OWNER_NAME.
export const TRUST_OWNER_NAME = "owner"

## Fixed release layout names inside an acquisition directory.
## RELEASE_METADATA_NAME.
export const RELEASE_METADATA_NAME = "metadata"
## RELEASE_SIGNATURE_NAME.
export const RELEASE_SIGNATURE_NAME = "metadata.sig"
## RELEASE_BUNDLE_NAME.
export const RELEASE_BUNDLE_NAME = "ca-certificates.crt"
## RELEASE_POLICY_NAME.
export const RELEASE_POLICY_NAME = "trust-policy"

pure trust_store_fail(message: Str) -> Error {
  TrustStoreError.InvalidData(message)
}

## trust_store_paths.
export pure trust_store_paths(system_root: Path) -> TrustStorePaths {
  let store = fp"{system_root}/var/lib/laputa/trust"
  {
    root: system_root,
    store,
    generations: fp"{store}/{TRUST_GENERATIONS_DIR}",
    staging: fp"{store}/{TRUST_STAGING_DIR}",
    active: fp"{store}/{TRUST_ACTIVE_NAME}",
    accepted: fp"{store}/{TRUST_ACCEPTED_NAME}",
    lower_bound: fp"{store}/{TRUST_LOWER_BOUND_NAME}",
    journal: fp"{store}/{TRUST_JOURNAL_NAME}",
    lock_file: fp"{store}/{TRUST_LOCK_NAME}",
  }
}

## trust_store_generation_dir.
export pure trust_store_generation_dir(paths: TrustStorePaths, generation: Str) -> Path {
  fp"{paths.generations}/{generation}"
}

## canonical_bundle_path.
export pure canonical_bundle_path(system_root: Path) -> Path {
  fp"{system_root}/etc/ssl/certs/ca-certificates.crt"
}

## canonical_policy_path.
export pure canonical_policy_path(system_root: Path) -> Path {
  fp"{system_root}/etc/laputa/trust-policy"
}

## seed_bundle_path.
export pure seed_bundle_path(system_root: Path) -> Path {
  fp"{system_root}/usr/share/laputa/trust/seed/ca-certificates.crt"
}

## seed_policy_path.
export pure seed_policy_path(system_root: Path) -> Path {
  fp"{system_root}/usr/share/laputa/trust/seed/trust-policy"
}

## provisioned_key_path.
export pure provisioned_key_path(system_root: Path) -> Path {
  fp"{system_root}/etc/laputa/trust-update-key"
}

## trust_store_read_active.
export proc trust_store_read_active(paths: TrustStorePaths) [fs, error] -> Result[Str, Error] {
  guard paths.active.is_symlink() else {
    if paths.active.exists() {
      return Err(trust_store_fail("active trust pointer is not a symlink; refusing to interpret it"))
    }

    return Err(trust_store_fail("no active trust generation is installed"))
  }

  let target = paths.active.readlink()?
  let text = target.display()
  let prefix = f"{TRUST_GENERATIONS_DIR}/"
  guard text.starts_with(prefix) else {
    return Err(trust_store_fail(f"active trust pointer escapes the generations directory: {text}"))
  }

  let generation = text.byte_slice(prefix.byte_len(), text.byte_len())
  guard ! ("/" in generation) and trust_policy.policy_u64_text_is_valid(generation) else {
    return Err(trust_store_fail(f"active trust pointer names an invalid generation: {text}"))
  }

  guard trust_store_generation_dir(paths, generation).exists() else {
    return Err(trust_store_fail(f"active trust pointer is dangling: {text}"))
  }

  generation
}

## trust_store_has_store.
export proc trust_store_has_store(paths: TrustStorePaths) [fs, error] -> Result[Bool, Error] {
  paths.generations.exists()?
}

## Whether the active generation pointer exists as a symlink.
## trust_store_active_present.
export proc trust_store_active_present(paths: TrustStorePaths) [fs, error] -> Result[Bool, Error] {
  match paths.active.is_symlink() {
    Ok(present) => Ok(present),
    Err(_) => Ok(false),
  }
}

## trust_store_take_lock.
export proc trust_store_take_lock(paths: TrustStorePaths) [fs, error] -> Result[FsLock, Error] {
  paths.store.mkdir(parents: true)
  match fs.lock(paths.lock_file, shared: false, nonblocking: true) {
    Ok(held) => held,
    Err(_) => return Err(
      trust_store_fail("another trust update holds the store lock; refusing to run concurrently"),
    ),
  }
}

## trust_store_read_accepted.
export proc trust_store_read_accepted(paths: TrustStorePaths) [fs, error] -> Result[Str, Error] {
  guard paths.accepted.exists() else {
    return Err(trust_store_fail("no accepted trust generation is recorded"))
  }

  let text = paths.accepted.read_text()?.trim()
  guard trust_policy.policy_u64_text_is_valid(text) else {
    return Err(trust_store_fail("accepted trust generation is corrupt; refusing to proceed"))
  }

  text
}

proc trust_store_write_line_durable(target: Path, line: Str) [fs, error] -> Result[Unit, Error] {
  let sibling = fs.temp_sibling(target)?
  sibling.write(bytes.from_text(line), mode: 0o644)
  fs.fsync(sibling)
  sibling.rename(to: target, overwrite: true)
  fs.fsync(target.parent)
}

## trust_store_persist_accepted.
export proc trust_store_persist_accepted(paths: TrustStorePaths, generation: Str) [fs, error] -> Result[Unit, Error] {
  guard trust_policy.policy_u64_text_is_valid(generation) else {
    return Err(trust_store_fail(f"refusing to persist an invalid accepted generation: {generation}"))
  }

  # The accepted file is the rollback high-water mark: never move it backward.
  # Re-persisting the current generation is an idempotent no-op.
  if paths.accepted.exists() {
    let current = trust_store_read_accepted(paths)?
    guard ! trust_policy.policy_u64_is_greater(current, generation) else {
      return Err(
        trust_store_fail(f"refusing to roll back the accepted generation from {current} to {generation}"),
      )
    }
  }

  trust_store_write_line_durable(paths.accepted, f"{generation}\n")
}

## trust_store_read_lower_bound.
export proc trust_store_read_lower_bound(paths: TrustStorePaths) [fs, error] -> Result[Int, Error] {
  guard paths.lower_bound.exists() else {
    return Ok(0)
  }

  let text = paths.lower_bound.read_text()?.trim()
  let seconds = text.parse_int_decimal()?
  guard seconds >= 0 and f"{seconds}" == text else {
    return Err(trust_store_fail("persisted trust time lower bound is corrupt; refusing to proceed"))
  }

  seconds
}

## trust_store_persist_lower_bound.
export proc trust_store_persist_lower_bound(paths: TrustStorePaths, seconds: Int) [fs, error] -> Result[Unit, Error] {
  guard seconds >= 0 else {
    return Err(trust_store_fail("refusing to persist a negative trust time lower bound"))
  }

  let current = trust_store_read_lower_bound(paths)?
  return when seconds <= current

  trust_store_write_line_durable(paths.lower_bound, f"{seconds}\n")
}

## Recovery journal state.
## TrustJournal.
export type TrustJournal = {present: Bool, phase: Str, generation: Str, staging: Str, token: Str}
## trust_store_read_journal.
export proc trust_store_read_journal(paths: TrustStorePaths) [fs, error] -> Result[TrustJournal, Error] {
  guard paths.journal.exists() else {
    return Ok({present: false, phase: "clean", generation: "", staging: "", token: ""})
  }

  let parsed: Result[TrustJournal, Error] = try {
    let value = json.read(paths.journal)?.require(Record)?
    {
      present: true,
      phase: value.get("phase")?.require(Str)?,
      generation: value.get("generation")?.require(Str)?,
      staging: value.get("staging")?.require(Str)?,
      token: value.get("token")?.require(Str)?,
    }
  }

  match parsed {
    Ok(record) => Ok(record),
    Err(_) => Ok({present: true, phase: "unknown", generation: "", staging: "", token: ""}),
  }
}

## trust_store_write_journal.
## The replacement is atomic: readers observe the previous complete phase or
## the next one, never a torn write from an interrupted phase transition.
export proc trust_store_write_journal(
  paths: TrustStorePaths,
  phase: Str,
  generation: Str,
  staging: Str,
  token: Str,
) [fs, error] -> Result[Unit, Error] {
  let sibling = fs.temp_sibling(paths.journal)?
  json.write(
    sibling,
    {format: "laputa-trust-journal-1", phase, generation, staging, token},
  )
  fs.fsync(sibling)
  sibling.rename(to: paths.journal, overwrite: true)
  fs.fsync(paths.journal)
  fs.fsync(paths.journal.parent)
}

## trust_store_clear_journal.
export proc trust_store_clear_journal(paths: TrustStorePaths) [fs, error] -> Result[Unit, Error] {
  guard paths.journal.exists() else {
    return
  }

  paths.journal.remove()
  fs.fsync(paths.journal.parent)
}

## trust_store_remove_owned_staging.
export proc trust_store_remove_owned_staging(paths: TrustStorePaths, staging: Str, token: Str) [fs, error] -> Result[Unit, Error] {
  guard staging != "" else {
    return
  }

  guard staging.starts_with(f"{TRUST_STAGING_DIR}/") and ! ("/" in staging.byte_slice(TRUST_STAGING_DIR.byte_len() + 1, staging.byte_len())) else {
    return Err(trust_store_fail(f"refusing to remove a staging path outside the staging directory: {staging}"))
  }

  let staging_path = fp"{paths.store}/{staging}"
  guard staging_path.exists() else {
    return
  }

  let owner_path = fp"{staging_path}/{TRUST_OWNER_NAME}"
  guard owner_path.exists() else {
    return Err(trust_store_fail(f"refusing to remove staging without an owner token: {staging}"))
  }

  guard owner_path.read_text()?.trim() == token else {
    return Err(trust_store_fail(f"staging owner token mismatch; refusing to remove: {staging}"))
  }

  staging_path.remove()
  fs.fsync(paths.staging)
}

## Staged candidate location and ownership token.
## TrustStagedCandidate.
export type TrustStagedCandidate = {path: Str, token: Str}
## trust_store_stage_candidate.
export proc trust_store_stage_candidate(
  paths: TrustStorePaths,
  generation: Str,
  bundle: Bytes,
  policy: Bytes,
  metadata: Bytes,
  signature: Bytes,
) [fs, process, time, error] -> Result[TrustStagedCandidate, Error] {
  guard trust_policy.policy_u64_text_is_valid(generation) else {
    return Err(trust_store_fail(f"refusing to stage an invalid generation: {generation}"))
  }

  paths.staging.mkdir(parents: true)
  fp"{paths.staging}".chmod(0o700)

  let pid = process.current_pid()?
  let base = f"candidate-{generation}-{pid}"
  var attempt = 0
  var staged = ""
  while attempt < 100 {
    let candidate = if attempt == 0 { base } else { f"{base}-{attempt}" }
    let staging_path = fp"{paths.staging}/{candidate}"
    guard ! staging_path.exists() else {
      attempt += 1
      continue
    }

    staging_path.mkdir()
    staged = f"{TRUST_STAGING_DIR}/{candidate}"
    break
  }

  guard staged != "" else {
    return Err(trust_store_fail("could not claim a unique trust staging directory"))
  }

  let staging_path = fp"{paths.store}/{staged}"
  staging_path.chmod(0o700)
  let now_ms = time.now()
  let token = f"{pid}-{now_ms}-{staged}"
  fp"{staging_path}/{TRUST_OWNER_NAME}".write(bytes.from_text(token), mode: 0o600)
  fp"{staging_path}/{TRUST_BUNDLE_NAME}".write(bundle, mode: 0o644)
  fp"{staging_path}/{TRUST_POLICY_NAME}".write(policy, mode: 0o644)
  fp"{staging_path}/{TRUST_METADATA_NAME}".write(metadata, mode: 0o644)
  fp"{staging_path}/{TRUST_SIGNATURE_NAME}".write(signature, mode: 0o644)
  fs.fsync(fp"{staging_path}/{TRUST_OWNER_NAME}")
  fs.fsync(fp"{staging_path}/{TRUST_BUNDLE_NAME}")
  fs.fsync(fp"{staging_path}/{TRUST_POLICY_NAME}")
  fs.fsync(fp"{staging_path}/{TRUST_METADATA_NAME}")
  fs.fsync(fp"{staging_path}/{TRUST_SIGNATURE_NAME}")
  fs.fsync(staging_path)

  guard fp"{staging_path}/{TRUST_BUNDLE_NAME}".read_bytes()? == bundle else {
    return Err(trust_store_fail("staged root bundle differs from verified bytes"))
  }

  guard fp"{staging_path}/{TRUST_POLICY_NAME}".read_bytes()? == policy else {
    return Err(trust_store_fail("staged trust policy differs from verified bytes"))
  }

  {path: staged, token}
}

## trust_store_commit_generation.
export proc trust_store_commit_generation(
  paths: TrustStorePaths,
  staging: Str,
  generation: Str,
) [fs, error] -> Result[Unit, Error] {
  let final = trust_store_generation_dir(paths, generation)
  guard ! final.exists() else {
    return Err(trust_store_fail(f"immutable trust generation already exists: {generation}"))
  }

  fp"{paths.store}/{staging}".rename(to: final)
  fs.fsync(paths.generations)
  fs.fsync(paths.staging)
}

## trust_store_verify_generation.
export proc trust_store_verify_generation(
  paths: TrustStorePaths,
  generation: Str,
  bundle_sha256: Str,
  policy_sha256: Str,
) [fs, error] -> Result[Unit, Error] {
  let dir = trust_store_generation_dir(paths, generation)
  guard dir.exists() else {
    return Err(trust_store_fail(f"trust generation is absent: {generation}"))
  }

  let bundle_path = fp"{dir}/{TRUST_BUNDLE_NAME}"
  let policy_path = fp"{dir}/{TRUST_POLICY_NAME}"
  guard bundle_path.read_bytes()?.sha256().hex() == bundle_sha256 else {
    return Err(trust_store_fail(f"trust generation bundle digest mismatch: {generation}"))
  }

  guard policy_path.read_bytes()?.sha256().hex() == policy_sha256 else {
    return Err(trust_store_fail(f"trust generation policy digest mismatch: {generation}"))
  }

  let parsed = trust_policy.parse(policy_path.read_bytes()?)?
  guard parsed.generation == generation else {
    return Err(trust_store_fail(f"trust generation policy names the wrong generation: {generation}"))
  }
}

## trust_store_flip_active.
export proc trust_store_flip_active(paths: TrustStorePaths, generation: Str) [fs, error] -> Result[Unit, Error] {
  let scratch = fp"{paths.store}/{TRUST_ACTIVE_SCRATCH_NAME}"
  guard ! scratch.exists() or scratch.is_symlink() else {
    return Err(trust_store_fail("active pointer scratch state is not a symlink; refusing to proceed"))
  }

  if scratch.exists() {
    scratch.remove()
  }

  let link = fp"{paths.store}/{TRUST_ACTIVE_SCRATCH_NAME}"
  link.symlink(to: fp"generations/{generation}")
  fs.fsync(paths.store)
  link.rename(to: paths.active, overwrite: true)
  fs.fsync(paths.store)
}

## Observed canonical trust state after re-reading.
## TrustEffectiveState.
export type TrustEffectiveState = {generation: Str, bundle_sha256: Str, policy_sha256: Str}
## trust_store_reobserve.
export proc trust_store_reobserve(
  paths: TrustStorePaths,
  expect_generation: Str,
  expect_bundle_sha256: Str,
  expect_policy_sha256: Str,
) [fs, error] -> Result[TrustEffectiveState, Error] {
  var attempt = 0
  while attempt < 8 {
    let observed = trust_store_read_active(paths)?
    let bundle = canonical_bundle_path(paths.root).read_bytes()?
    let policy = canonical_policy_path(paths.root).read_bytes()?
    let stable = trust_store_read_active(paths)?
    guard observed == stable else {
      attempt += 1
      continue
    }

    guard observed == expect_generation else {
      return Err(
        trust_store_fail(
          f"canonical trust points at generation {observed}, expected {expect_generation}",
        ),
      )
    }

    guard bundle.sha256().hex() == expect_bundle_sha256 else {
      return Err(trust_store_fail("canonical root bundle differs from the activated generation"))
    }

    guard policy.sha256().hex() == expect_policy_sha256 else {
      return Err(trust_store_fail("canonical trust policy differs from the activated generation"))
    }

    return {generation: observed, bundle_sha256: expect_bundle_sha256, policy_sha256: expect_policy_sha256}
  }

  Err(trust_store_fail("canonical trust paths changed during re-observation; retry the update"))
}

## trust_store_bootstrap_from_seeds.
export proc trust_store_bootstrap_from_seeds(system_root: Path) [fs, error] -> Result[Str, Error] {
  let paths = trust_store_paths(system_root)
  let seed_bundle = seed_bundle_path(system_root).read_bytes()?
  let seed_policy = seed_policy_path(system_root).read_bytes()?
  net.validate_root_bundle(seed_bundle)
  let parsed = trust_policy.parse(seed_policy)?
  let generation = parsed.generation
  let bundle_digest = seed_bundle.sha256().hex()
  let policy_digest = seed_policy.sha256().hex()

  guard canonical_bundle_path(system_root).is_symlink() else {
    return Err(
      trust_store_fail(
        "canonical root bundle is not a managed symlink; upgrade ca-certificates before updating trust",
      ),
    )
  }

  guard canonical_policy_path(system_root).is_symlink() else {
    return Err(
      trust_store_fail(
        "canonical trust policy is not a managed symlink; upgrade ca-certificates before updating trust",
      ),
    )
  }

  if paths.accepted.exists() {
    let accepted = trust_store_read_accepted(paths)?
    guard accepted == generation else {
      return Err(
        trust_store_fail(
          f"accepted generation {accepted} is already installed; refusing to bootstrap seeds over it",
        ),
      )
    }
  }

  if paths.active.exists() or trust_store_active_present(paths) {
    let active = match trust_store_read_active(paths) {
      Ok(found) => found,
      Err(_) => {
        return Err(
          trust_store_fail(
            "active trust pointer is unreadable; refusing to bootstrap over installed state",
          ),
        )
      },
    }
    guard active == generation else {
      return Err(
        trust_store_fail(
          f"active generation {active} is already installed; refusing to bootstrap seeds over it",
        ),
      )
    }
  }

  if paths.journal.exists() {
    return Err(
      trust_store_fail(
        "a trust update journal is pending; refusing to bootstrap over it",
      ),
    )
  }

  if paths.generations.exists() {
    for entry in fs.children(paths.generations)? {
      guard entry.name == generation else {
        return Err(
          trust_store_fail(
            f"trust generation {entry.name} is already installed; refusing to bootstrap seeds over it",
          ),
        )
      }
    }

    let dir = trust_store_generation_dir(paths, generation)
    if dir.exists() {
      trust_store_verify_generation(paths, generation, bundle_digest, policy_digest)
    }
  }

  let dir = trust_store_generation_dir(paths, generation)
  if ! dir.exists() {
    paths.generations.mkdir(parents: true)
    dir.mkdir()
    fp"{dir}/{TRUST_BUNDLE_NAME}".write(seed_bundle)
    fp"{dir}/{TRUST_POLICY_NAME}".write(seed_policy)
    fp"{dir}/{TRUST_OWNER_NAME}".write(bytes.from_text("package-seed\n"))
    fs.fsync(fp"{dir}/{TRUST_BUNDLE_NAME}")
    fs.fsync(fp"{dir}/{TRUST_POLICY_NAME}")
    fs.fsync(fp"{dir}/{TRUST_OWNER_NAME}")
    fs.fsync(dir)
    fs.fsync(paths.generations)
  }

  trust_store_verify_generation(paths, generation, bundle_digest, policy_digest)
  trust_store_flip_active(paths, generation)

  let accepted_path = fp"{paths.store}/{TRUST_ACCEPTED_NAME}"
  if ! accepted_path.exists() {
    trust_store_persist_accepted(paths, generation)
  } else {
    let accepted = trust_store_read_accepted(paths)?
    guard ! trust_policy.policy_u64_is_greater(accepted, generation) else {
      return Err(
        trust_store_fail(
          f"accepted generation {accepted} is newer than package seeds; refusing to bootstrap over them",
        ),
      )
    }

    trust_store_persist_accepted(paths, generation)
  }

  let _ = trust_store_reobserve(paths, generation, bundle_digest, policy_digest)?
  generation
}
