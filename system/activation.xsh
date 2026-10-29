##! Host record of which generation the launcher boots and which fallback it keeps.

## Refused activation transition.
export error ActivationError = Rejected(message: Str)

## Persisted activation record file name.
export const ACTIVATION_RECORD_NAME = "activation.json"
## Exclusive activation lock file name.
export const ACTIVATION_LOCK_NAME = "activation.lock"
## Boot attempts allowed before the launcher selects the fallback.
export const ACTIVATION_MAX_BOOT_ATTEMPTS = 2
## Age after which an abandoned activation lock may be replaced.
export const ACTIVATION_LOCK_DEADLINE = 24h

const ACTIVATION_EEXIST = 17

## One installed generation the launcher can select.
export type GenerationReceipt = {
  id: Str,
  kernel: Str,
  root_digest: Str,
}

## Durable current, fallback, and pending generation selection.
export type ActivationRecord = {
  current: GenerationReceipt,
  fallback: GenerationReceipt,
  pending: GenerationReceipt?,
  boot_attempts: Int,
  max_boot_attempts: Int,
  last_operation: Str,
}

## Result of selecting the pending generation for one boot.
export enum ActivationBoot {
  PendingBoot(Str),
  FellBack(Str),
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

pure activation_receipt_ok(receipt: GenerationReceipt) -> Bool {
  receipt.id != "" and receipt.kernel != "" and activation_digest_ok(receipt.root_digest)
}

pure activation_pending_ok(pending: GenerationReceipt?) -> Bool {
  if pending == null {
    true
  } else {
    activation_receipt_ok(pending)
  }
}

pure activation_record_ok(record: ActivationRecord) -> Bool {
  activation_receipt_ok(record.current) and activation_receipt_ok(record.fallback) and activation_pending_ok(record.pending) and record.boot_attempts >= 0 and record.max_boot_attempts == ACTIVATION_MAX_BOOT_ATTEMPTS and record.last_operation != ""
}

proc activation_record_path(state_dir: Path) -> Path {
  fp"{state_dir}/{ACTIVATION_RECORD_NAME}"
}

proc activation_lock_path(state_dir: Path) -> Path {
  fp"{state_dir}/{ACTIVATION_LOCK_NAME}"
}

proc activation_try_lock(lock_file: Path) -> Result[Bool, Error] {
  match fs.mknod(lock_file, "file", 0o600) {
    Ok(_) => true
    Err(failure) => {
      return Err(failure) when failure.errno != ACTIVATION_EEXIST
      false
    }
  }
}

proc activation_lock_expired(lock_file: Path, deadline: Duration) -> Result[Bool, Error] {
  let age_ns = time.now() - fs.stat(lock_file)?.mtime_ns
  let limit_ns = deadline / 1ms * 1000000
  age_ns > limit_ns
}

proc activation_acquire_lock(state_dir: Path, deadline: Duration) -> Result[Path, Error] {
  let lock_file = activation_lock_path(state_dir)
  return lock_file when activation_try_lock(lock_file)
  guard activation_lock_expired(lock_file, deadline) else {
    return Err(activation_reject("activation lock is held"))
  }
  lock_file.unlink()
  guard activation_try_lock(lock_file) else {
    return Err(activation_reject("activation lock is held"))
  }
  lock_file
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
  let sibling = fs.temp_sibling(target)?
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
  lock_deadline = ACTIVATION_LOCK_DEADLINE,
) [fs, time, error] -> Result[Unit, Error] {
  guard activation_receipt_ok(receipt) else {
    return Err(activation_reject("generation receipt is invalid"))
  }
  let lock = activation_acquire_lock(state_dir, lock_deadline)?
  defer lock.unlink()
  guard ! activation_record_path(state_dir).exists() else {
    return Err(activation_reject("activation record already exists"))
  }
  activation_write(state_dir, {
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
  lock_deadline = ACTIVATION_LOCK_DEADLINE,
) [fs, time, error] -> Result[Unit, Error] {
  guard activation_receipt_ok(candidate) else {
    return Err(activation_reject("generation receipt is invalid"))
  }
  let lock = activation_acquire_lock(state_dir, lock_deadline)?
  defer lock.unlink()
  let record = activation_status(state_dir)?
  guard candidate.id != record.current.id else {
    return Err(activation_reject("refusing to stage the current generation"))
  }
  guard record.pending == null else {
    return Err(activation_reject("a generation is already pending"))
  }
  activation_write(state_dir, {...record, pending: candidate, boot_attempts: 0, last_operation: "staged"})
}

## Count one boot of the pending generation, or select the fallback when another attempt would pass the cap.
export proc activation_begin_boot(
  state_dir: Path,
  lock_deadline = ACTIVATION_LOCK_DEADLINE,
) [fs, time, error] -> Result[ActivationBoot, Error] {
  let lock = activation_acquire_lock(state_dir, lock_deadline)?
  defer lock.unlink()
  let record = activation_status(state_dir)?
  let pending = activation_require_pending(record)?
  if record.boot_attempts >= ACTIVATION_MAX_BOOT_ATTEMPTS {
    activation_write(state_dir, {
      ...record,
      current: record.fallback,
      pending: null,
      last_operation: "fell-back",
    })
    return FellBack(record.fallback.id)
  }
  activation_write(state_dir, {
    ...record,
    boot_attempts: record.boot_attempts + 1,
    last_operation: "pending-boot",
  })
  PendingBoot(pending.id)
}

## Commit the pending generation after a boot attempt when its id matches.
export proc activation_confirm_health(
  state_dir: Path,
  id: Str,
  lock_deadline = ACTIVATION_LOCK_DEADLINE,
) [fs, time, error] -> Result[Unit, Error] {
  let lock = activation_acquire_lock(state_dir, lock_deadline)?
  defer lock.unlink()
  let record = activation_status(state_dir)?
  let pending = activation_require_pending(record)?
  guard pending.id == id else {
    return Err(activation_reject("pending generation does not match"))
  }
  guard record.boot_attempts >= 1 else {
    return Err(activation_reject("generation has not booted"))
  }
  activation_write(state_dir, {
    current: pending,
    fallback: record.current,
    pending: null,
    boot_attempts: 0,
    max_boot_attempts: record.max_boot_attempts,
    last_operation: "confirmed",
  })
}

## Record a failed boot, selecting the fallback once the attempt cap is met.
export proc activation_boot_failed(
  state_dir: Path,
  lock_deadline = ACTIVATION_LOCK_DEADLINE,
) [fs, time, error] -> Result[Unit, Error] {
  let lock = activation_acquire_lock(state_dir, lock_deadline)?
  defer lock.unlink()
  let record = activation_status(state_dir)?
  let _ = activation_require_pending(record)?
  guard record.boot_attempts >= 1 else {
    return Err(activation_reject("generation has not booted"))
  }
  if record.boot_attempts < record.max_boot_attempts {
    return activation_write(state_dir, {...record, last_operation: "boot-failed"})
  }
  activation_write(state_dir, {
    ...record,
    current: record.fallback,
    pending: null,
    last_operation: "fell-back",
  })
}

