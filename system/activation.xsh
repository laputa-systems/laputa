##! Host record of which generation the launcher boots and which fallback it keeps.

## Refused activation transition.
export error ActivationError = Rejected(message: Str)

## Persisted activation record file name.
export const ACTIVATION_RECORD_NAME = "activation.json"
## Exclusive activation lock file name.
export const ACTIVATION_LOCK_NAME = "activation.flock"
## Boot attempts allowed before the launcher selects the fallback.
export const ACTIVATION_MAX_BOOT_ATTEMPTS = 2
## Activation record version containing host admission policy.
export const ACTIVATION_FORMAT = "laputa-activation-4"
## Shared state format accepted for every admitted generation; migrations are refused.
export const ACTIVATION_STATE_FORMAT = "laputa-maintained-state-1"

## One installed generation the launcher can select.
export type GenerationReceipt = {
  id: Str,
  kernel: Str,
  root_digest: Str,
}

## Host-authorized artifact hashes and the shared state contract for one generation.
export type ImageAdmission = {generation: GenerationReceipt, state_format: Str, kernel_sha256: Str, disk_sha256: Str}
## Monotonic host policy; an empty image set requires independent rescue.
export type AdmissionPolicy = {revision: Int, images: List[ImageAdmission]}
type ImageReceipt = {format: Str, admission: ImageAdmission}

## Verified files for one published activation generation.
export type GenerationImage = {id: Str, kernel_file: Path, disk_file: Path}
## Verified and admitted boot image with its durable boot sequence. `failed`
## names the pending receipt the launcher is falling back from, if any, so a
## fallback boot can report which generation did not come up.
export type ActivationLaunch = {image: GenerationImage, boot_serial: Int, failed: GenerationReceipt?}

## Durable current, fallback, and pending generation selection.
export type ActivationRecord = {
  format: Str,
  admission_policy: AdmissionPolicy,
  boot_serial: Int,
  current: GenerationReceipt,
  fallback: GenerationReceipt,
  pending: GenerationReceipt?,
  boot_attempts: Int,
  max_boot_attempts: Int,
  last_operation: Str,
}

## Result of selecting the pending generation for one boot.
export type BootSelection = {id: Str, serial: Int}

## One named service state observed by the guest supervisor.
export type ServiceHealth = {name: Str, state: Str}

## Fresh guest identity and observed service states from one selected boot.
export type GuestHealthReport = {
  format: Str,
  generation_id: Str,
  boot_serial: Int,
  root_digest: Str,
  profile: Str,
  services: List[ServiceHealth],
}

## Host-owned health requirements for an installed system profile.
export type HealthPolicy = {profile: Str, critical_services: List[Str]}

## Pending or fallback selection with its persistent boot sequence.
export enum ActivationBoot {
  PendingBoot(BootSelection),
  FellBack(BootSelection),
}

pure activation_reject(message: Str) -> Error {
  ActivationError.Rejected(message)
}

pure activation_digest_ok(digest: Str) -> Bool {
  return false when digest.byte_len() != 64
  for digit in digest {
    return false when "0123456789abcdefABCDEF".find(digit) == null
  }
  true
}

pure generation_id_ok(id: Str) -> Bool {
  return false when id == "" or id.byte_len() > 128 or id.starts_with(".") or id.starts_with("-") or id.starts_with("_")
  for character in id {
    return false when "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".find(character) == null
  }
  true
}

pure activation_receipt_ok(receipt: GenerationReceipt) -> Bool {
  generation_id_ok(receipt.id) and receipt.kernel != "" and activation_digest_ok(receipt.root_digest)
}

pure activation_pending_ok(pending: GenerationReceipt?) -> Bool {
  if pending == null {
    true
  } else {
    activation_receipt_ok(pending)
  }
}

pure activation_record_ok(record: ActivationRecord) -> Bool {
  record.format == ACTIVATION_FORMAT and activation_policy_ok(record.admission_policy) and record.boot_serial >= record.boot_attempts and activation_receipt_ok(record.current) and activation_receipt_ok(record.fallback) and activation_pending_ok(record.pending) and record.boot_attempts >= 0 and record.max_boot_attempts == ACTIVATION_MAX_BOOT_ATTEMPTS and record.last_operation != ""
}

pure activation_policy_ok(policy: AdmissionPolicy) -> Bool {
  return false when policy.revision < 1
  var ids: List[Str] = []
  for image in policy.images {
    return false when ! activation_receipt_ok(image.generation) or image.state_format != ACTIVATION_STATE_FORMAT or ! activation_digest_ok(image.kernel_sha256) or ! activation_digest_ok(image.disk_sha256) or image.generation.id in ids
    ids += [image.generation.id]
  }
  true
}

## Publish already verified inputs under a new id without replacing retained images.
export proc activation_publish_image(state_dir: Path, receipt: GenerationReceipt, kernel: Path, disk: Path, state_format: Str) [fs, error] -> Result[ImageAdmission, Error] {
  guard activation_receipt_ok(receipt) else { fail "generation receipt is invalid" }
  guard state_format != "" else { fail "generation state format is missing" }
  let images = fp"{state_dir}/images"
  images.mkdir()
  fs.fsync(state_dir)
  let temporary = fs.tempdir_in(images)?
  let bundle = fp"{temporary.host_path()?}/bundle"
  bundle.mkdir()
  kernel.copy(to: fp"{bundle}/kernel")
  disk.copy(to: fp"{bundle}/disk")
  let admission = ImageAdmission(
    generation: receipt,
    state_format: state_format,
    kernel_sha256: hash.sha256(fp"{bundle}/kernel")?.hex(),
    disk_sha256: hash.sha256(fp"{bundle}/disk")?.hex(),
  )
  let metadata = ImageReceipt(format: "laputa-activation-image-2", admission: admission)
  fp"{bundle}/receipt.json".write(json.encode(metadata)? + "\n")
  for item in [p"kernel", p"disk", p"receipt.json"] { fs.fsync(fp"{bundle}/{item}") }
  fs.fsync(bundle)
  bundle.rename(to: fp"{images}/{receipt.id}", overwrite: false)
  fs.fsync(images)
  admission
}

## Verify a published bundle against its activation receipt before admission or boot.
export proc activation_verify_image(state_dir: Path, receipt: GenerationReceipt) [fs, error] -> Result[GenerationImage, Error] {
  guard activation_receipt_ok(receipt) else { fail "generation receipt is invalid" }
  let bundle = fp"{state_dir}/images/{receipt.id}"
  let image = GenerationImage(id: receipt.id, kernel_file: fp"{bundle}/kernel", disk_file: fp"{bundle}/disk")
  guard image.kernel_file.exists() and image.disk_file.exists() else { fail "generation image is missing" }
  let metadata = json.read(fp"{bundle}/receipt.json")?.require_exact(ImageReceipt)?
  guard metadata.format == "laputa-activation-image-2" and metadata.admission.generation == receipt else { fail "generation image receipt differs" }
  guard hash.sha256(image.kernel_file)?.hex() == metadata.admission.kernel_sha256 and hash.sha256(image.disk_file)?.hex() == metadata.admission.disk_sha256 else { fail "generation image digest differs" }
  image
}

proc activation_admitted_image(state_dir: Path, policy: AdmissionPolicy, receipt: GenerationReceipt) -> Result[GenerationImage, Error] {
  let metadata = json.read(fp"{state_dir}/images/{receipt.id}/receipt.json")?.require_exact(ImageReceipt)?
  guard metadata.format == "laputa-activation-image-2" and metadata.admission.state_format == ACTIVATION_STATE_FORMAT and metadata.admission in policy.images else {
    fail "generation is not admitted by the current host policy; independent rescue may be required"
  }
  activation_verify_image(state_dir, receipt)?
}

## Replace host admission pins at a strictly greater revision without changing boot selection.
export proc activation_update_policy(state_dir: Path, policy: AdmissionPolicy) [fs, error] -> Result[Unit, Error] {
  guard activation_policy_ok(policy) else { fail "activation admission policy is invalid or requires incompatible state" }
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  guard policy.revision > record.admission_policy.revision else { fail "activation admission policy revision must increase" }
  activation_write(state_dir, {...record, admission_policy: policy})
}

proc activation_record_path(state_dir: Path) -> Path {
  fp"{state_dir}/{ACTIVATION_RECORD_NAME}"
}

proc activation_lock_path(state_dir: Path) -> Path {
  fp"{state_dir}/{ACTIVATION_LOCK_NAME}"
}

proc activation_acquire_lock(state_dir: Path) -> Result[FsLock, Error] {
  match fs.lock(activation_lock_path(state_dir), false, true) {
    Ok(lock) => lock
    Err(failure) => {
      if failure.errno == 11 or failure.errno == 35 {
        return Err(activation_reject("activation lock is held"))
      }
      Err(failure)
    }
  }
}

## Read the activation record without changing it.
export proc activation_status(state_dir: Path) [fs, error] -> Result[ActivationRecord, Error] {
  let record_file = activation_record_path(state_dir)
  guard record_file.exists() else {
    return Err(activation_reject("activation record is missing"))
  }
  let parsed = json.read(record_file)
  if let Err(_) = parsed {
    return Err(activation_reject("activation record is unreadable"))
  }
  let checked = parsed?.require_exact(ActivationRecord)
  if let Err(_) = checked {
    return Err(activation_reject("activation record is unreadable"))
  }
  let record = checked?
  guard activation_record_ok(record) else {
    return Err(activation_reject("activation record is unreadable"))
  }
  record
}

proc activation_write(state_dir: Path, record: ActivationRecord) {
  let target = activation_record_path(state_dir)
  let sibling = fp"{state_dir}/activation.next"
  sibling.remove()
  fs.mknod(sibling, "file", 0o600)
  errdefer sibling.remove()
  sibling.write(json.encode(record)? + "\n", mode: 0o644)
  fs.fsync(sibling)
  sibling.rename(to: target, overwrite: true)
  fs.fsync(state_dir)
}

proc activation_require_pending(record: ActivationRecord) -> Result[GenerationReceipt, Error] {
  if record.pending == null {
    Err(activation_reject("no pending generation"))
  } else {
    record.pending
  }
}

## Record the first current generation and an equal fallback.
export proc activation_install(
  state_dir: Path,
  receipt: GenerationReceipt,
  policy: AdmissionPolicy,
) [fs, time, error] -> Result[Unit, Error] {
  guard activation_receipt_ok(receipt) else {
    return Err(activation_reject("generation receipt is invalid"))
  }
  let lock = activation_acquire_lock(state_dir)?
  guard ! activation_record_path(state_dir).exists() else {
    return Err(activation_reject("activation record already exists"))
  }
  guard activation_policy_ok(policy) else { fail "activation admission policy is invalid or requires incompatible state" }
  let _ = activation_admitted_image(state_dir, policy, receipt)?
  activation_write(state_dir, {
    format: ACTIVATION_FORMAT,
    admission_policy: policy,
    boot_serial: 0,
    current: receipt,
    fallback: receipt,
    pending: null,
    boot_attempts: 0,
    max_boot_attempts: ACTIVATION_MAX_BOOT_ATTEMPTS,
    last_operation: "installed",
  })
}

## Record a candidate without changing the current or fallback generation.
export proc activation_stage(
  state_dir: Path,
  candidate: GenerationReceipt,
) [fs, time, error] -> Result[Unit, Error] {
  guard activation_receipt_ok(candidate) else {
    return Err(activation_reject("generation receipt is invalid"))
  }
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  guard candidate.id != record.current.id else {
    return Err(activation_reject("refusing to stage the current generation"))
  }
  guard record.pending == null else {
    return Err(activation_reject("a generation is already pending"))
  }
  let _ = activation_admitted_image(state_dir, record.admission_policy, candidate)?
  activation_write(state_dir, {...record, fallback: record.current, pending: candidate, boot_attempts: 0, last_operation: "staged"})
}

## Count one boot of the pending generation, or select the fallback when another attempt would pass the cap.
export proc activation_begin_boot(
  state_dir: Path,
) [fs, time, error] -> Result[ActivationBoot, Error] {
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  let _ = activation_admitted_selection(state_dir, record)?
  activation_begin_boot_record(state_dir, record)?
}

pure activation_next_receipt(record: ActivationRecord) -> GenerationReceipt {
  if record.pending == null { record.current } else if record.boot_attempts >= ACTIVATION_MAX_BOOT_ATTEMPTS { record.fallback } else { record.pending }
}

proc activation_admitted_selection(state_dir: Path, record: ActivationRecord) -> Result[GenerationImage, Error] {
  match activation_admitted_image(state_dir, record.admission_policy, activation_next_receipt(record)) {
    Ok(image) => image
    Err(problem) => {
      if record.pending != null and record.boot_attempts >= ACTIVATION_MAX_BOOT_ATTEMPTS and record.last_operation != "boot-failed" {
        activation_write(state_dir, {...record, last_operation: "boot-failed"})
      }
      Err(problem)
    }
  }
}

## Check current policy and image bytes under the writer lock before counting a boot.
export proc activation_select_image(state_dir: Path) [fs, time, error] -> Result[ActivationLaunch, Error] {
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  let image = activation_admitted_selection(state_dir, record)?
  return {image, boot_serial: record.boot_serial, failed: null} when record.pending == null
  let selection = activation_begin_boot_record(state_dir, record)?
  let serial = match selection {
    PendingBoot(boot) => boot.serial
    FellBack(boot) => boot.serial
  }
  let failed = match selection {
    PendingBoot(_) => null
    FellBack(_) => record.pending
  }
  {image, boot_serial: serial, failed: failed}
}

proc activation_begin_boot_record(state_dir: Path, record: ActivationRecord) -> Result[ActivationBoot, Error] {
  let pending = activation_require_pending(record)?
  if record.boot_attempts >= ACTIVATION_MAX_BOOT_ATTEMPTS {
    activation_write(state_dir, {
      ...record,
      current: record.fallback,
      pending: null,
      last_operation: "fell-back",
    })
    return FellBack({id: record.fallback.id, serial: record.boot_serial})
  }
  activation_write(state_dir, {
    ...record,
    boot_attempts: record.boot_attempts + 1,
    boot_serial: record.boot_serial + 1,
    last_operation: "pending-boot",
  })
  PendingBoot({id: pending.id, serial: record.boot_serial + 1})
}

## Commit the pending generation after a boot attempt when its id matches.
export proc activation_confirm_health(
  state_dir: Path,
  id: Str,
) [fs, time, error] -> Result[Unit, Error] {
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  let pending = activation_require_pending(record)?
  guard pending.id == id else {
    return Err(activation_reject("pending generation does not match"))
  }
  guard record.boot_attempts >= 1 else {
    return Err(activation_reject("generation has not booted"))
  }
  guard record.last_operation == "pending-boot" else {
    return Err(activation_reject("generation boot is no longer confirmable"))
  }
  let _ = activation_admitted_image(state_dir, record.admission_policy, pending)?
  let _ = activation_admitted_image(state_dir, record.admission_policy, record.fallback)?
  activation_write(state_dir, {
    format: record.format,
    admission_policy: record.admission_policy,
    boot_serial: record.boot_serial,
    current: pending,
    fallback: record.current,
    pending: null,
    boot_attempts: 0,
    max_boot_attempts: record.max_boot_attempts,
    last_operation: "confirmed",
  })
}

## Confirm only a fresh guest report that matches the pending receipt and host health policy.
export proc activation_confirm_guest_health(
  state_dir: Path,
  report: GuestHealthReport,
  policy: HealthPolicy,
) [fs, time, error] -> Result[Unit, Error] {
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  let pending = activation_require_pending(record)?
  guard report.format == "laputa-guest-health-1" and report.generation_id == pending.id and report.root_digest == pending.root_digest and report.profile == policy.profile else {
    fail "guest health identity differs"
  }
  guard record.last_operation == "pending-boot" and record.boot_attempts > 0 and report.boot_serial == record.boot_serial else {
    fail "guest health report is stale"
  }
  guard ! policy.critical_services.is_empty() else { fail "critical service health policy is empty" }
  let _ = activation_admitted_image(state_dir, record.admission_policy, pending)?
  let _ = activation_admitted_image(state_dir, record.admission_policy, record.fallback)?
  for name in policy.critical_services {
    let matches = report.services |> where .name == name |> collect
    guard matches.len() == 1 else { fail f"critical service observation is missing or duplicated: {name}" }
    guard matches[0].state == "running" else { fail f"critical service is not healthy: {name}" }
  }
  activation_write(state_dir, {
    ...record,
    current: pending,
    fallback: record.current,
    pending: null,
    boot_attempts: 0,
    last_operation: "confirmed",
  })
}

## Record a failed boot, selecting the fallback once the attempt cap is met.
export proc activation_boot_failed(
  state_dir: Path,
) [fs, time, error] -> Result[Unit, Error] {
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  let _ = activation_require_pending(record)?
  guard record.boot_attempts >= 1 else {
    return Err(activation_reject("generation has not booted"))
  }
  if record.boot_attempts < record.max_boot_attempts {
    return activation_write(state_dir, {...record, last_operation: "boot-failed"})
  }
  match activation_admitted_image(state_dir, record.admission_policy, record.fallback) {
    Ok(_) => {}
    Err(problem) => {
      activation_write(state_dir, {...record, last_operation: "boot-failed"})
      return Err(problem)
    }
  }
  activation_write(state_dir, {
    ...record,
    current: record.fallback,
    pending: null,
    last_operation: "fell-back",
  })
}


## Collect only complete image ids outside current, fallback, and pending under the writer lock.
export proc activation_collect_images(state_dir: Path) [fs, error] -> Result[List[Str], Error] {
  let lock = activation_acquire_lock(state_dir)?
  let record = activation_status(state_dir)?
  var retained = [record.current.id, record.fallback.id]
  if record.pending != null { retained += [record.pending.id] }
  var removed: List[Str] = []
  let images = fp"{state_dir}/images"
  for candidate in fs.children(images)? {
    let id = candidate.name
    if generation_id_ok(id) and ! (id in retained) {
      candidate.path.remove()
      removed += [id]
    }
  }
  if ! removed.is_empty() { fs.fsync(images) }
  removed
}
