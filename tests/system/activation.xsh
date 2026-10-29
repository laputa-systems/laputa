##! Behavior coverage for the host generation activation record.
use system.activation

proc sha256_text(text: Str) -> Str {
  bytes.from_text(text).sha256().hex()
}

proc generation(id: Str) -> activation.GenerationReceipt {
  {id: id, kernel: f"boot/vmlinuz-{id}", root_digest: sha256_text(id)}
}

proc state_dir(ctx: TestContext, name: Str) -> Result[Path, Error] {
  test.temp_dir(ctx, name:)
}

proc record_text(state: Path) -> Result[Str, Error] {
  fp"{state}/{activation.ACTIVATION_RECORD_NAME}".read_text()
}

proc assert_pending(record: activation.ActivationRecord, id: Str) {
  if record.pending == null {
    assert false, "missing pending generation"
  } else {
    assert record.pending.id == id
  }
}

proc health_services(names: List[Str], state: Str) -> List[activation.ServiceHealth] {
  [activation.ServiceHealth(name: name, state: state) for name in names]
}

test test_guest_health_requires_current_boot_identity_and_critical_services [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-guest-health")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let _ = activation.activation_begin_boot(state)?
  let report = activation.GuestHealthReport(format: "laputa-guest-health-1", generation_id: "b", boot_serial: 1, root_digest: sha256_text("b"), profile: "qemu-maintained", services: health_services(["dropbear", "firewall"], "running"))
  let policy = activation.HealthPolicy(profile: "qemu-maintained", critical_services: ["firewall", "dropbear"])
  let before = record_text(state)?
  let invalid: List[activation.GuestHealthReport] = [
    {...report, root_digest: sha256_text("tampered")},
    {...report, generation_id: "a"},
    {...report, boot_serial: 0},
    {...report, services: health_services(["dropbear"], "running")},
    {...report, services: health_services(["dropbear", "firewall"], "dead")},
    {...report, services: health_services(["dropbear", "firewall", "dropbear"], "running")},
  ]
  for candidate in invalid {
    assert activation.activation_confirm_guest_health(state, candidate, policy) is Err(_)
    assert record_text(state)? == before
  }
  activation.activation_confirm_guest_health(state, report, policy)
  let confirmed = activation.activation_status(state)?
  assert confirmed.current.id == "b"
  assert confirmed.fallback.id == "a"
  assert confirmed.pending == null
  assert confirmed.boot_serial == 1
}

test test_a_later_boot_rejects_a_delayed_health_report [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-delayed-health")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let _ = activation.activation_begin_boot(state)?
  let _ = activation.activation_begin_boot(state)?
  let report = activation.GuestHealthReport(format: "laputa-guest-health-1", generation_id: "b", boot_serial: 1, root_digest: sha256_text("b"), profile: "qemu-maintained", services: health_services(["dropbear"], "running"))
  let before = record_text(state)?
  assert activation.activation_confirm_guest_health(state, report, {profile: "qemu-maintained", critical_services: ["dropbear"]}) is Err(_)
  assert record_text(state)? == before
}

test test_a_failed_attempt_cannot_confirm_a_delayed_health_report [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-failed-health")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let _ = activation.activation_begin_boot(state)?
  let report = activation.GuestHealthReport(format: "laputa-guest-health-1", generation_id: "b", boot_serial: 1, root_digest: sha256_text("b"), profile: "qemu-maintained", services: health_services(["dropbear"], "running"))
  activation.activation_boot_failed(state)
  let before = record_text(state)?
  assert activation.activation_confirm_guest_health(state, report, {profile: "qemu-maintained", critical_services: ["dropbear"]}) is Err(_)
  assert record_text(state)? == before
}

test test_stage_boot_and_confirm_moves_fallback_forward [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-confirm")?
  let installed = generation("a")
  activation.activation_install(state, installed)
  let before_boot = record_text(state)?
  match activation.activation_begin_boot(state) {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert record_text(state)? == before_boot

  activation.activation_stage(state, generation("b"))
  let staged = activation.activation_status(state)?
  assert staged.current.id == "a"
  assert staged.fallback.id == "a"
  assert staged.current.kernel == installed.kernel
  assert staged.current.root_digest == installed.root_digest
  assert_pending(staged, "b")
  assert staged.boot_attempts == 0
  assert staged.max_boot_attempts == 2
  assert staged.last_operation == "staged"

  match activation.activation_begin_boot(state)? {
    activation.PendingBoot(id) => assert id.id == "b"
    activation.FellBack(id) => assert false, id.id
  }
  let booting = activation.activation_status(state)?
  assert booting.current.id == "a"
  assert booting.fallback.id == "a"
  assert_pending(booting, "b")
  assert booting.boot_attempts == 1
  assert booting.last_operation == "pending-boot"

  activation.activation_confirm_health(state, "b")
  let confirmed = activation.activation_status(state)?
  assert confirmed.current.id == "b"
  assert confirmed.current.kernel == "boot/vmlinuz-b"
  assert confirmed.current.root_digest == sha256_text("b")
  assert confirmed.fallback.id == "a"
  assert confirmed.fallback.root_digest == installed.root_digest
  assert confirmed.pending == null
  assert confirmed.boot_attempts == 0
  assert confirmed.last_operation == "confirmed"
}

test test_two_failed_boots_restore_the_fallback [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-unbootable")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let staged = record_text(state)?
  match activation.activation_boot_failed(state) {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert record_text(state)? == staged

  match activation.activation_begin_boot(state)? {
    activation.PendingBoot(id) => assert id.id == "b"
    activation.FellBack(id) => assert false, id.id
  }
  activation.activation_boot_failed(state)
  let once = activation.activation_status(state)?
  assert once.current.id == "a"
  assert once.fallback.id == "a"
  assert_pending(once, "b")
  assert once.boot_attempts == 1
  assert once.last_operation == "boot-failed"

  match activation.activation_begin_boot(state)? {
    activation.PendingBoot(id) => assert id.id == "b"
    activation.FellBack(id) => assert false, id.id
  }
  activation.activation_boot_failed(state)
  let restored = activation.activation_status(state)?
  assert restored.current.id == "a"
  assert restored.fallback.id == "a"
  assert restored.pending == null
  assert restored.boot_attempts == 2
  assert restored.last_operation == "fell-back"

  activation.activation_stage(state, generation("c"))
  let restaged = activation.activation_status(state)?
  assert restaged.current.id == "a"
  assert restaged.fallback.id == "a"
  assert_pending(restaged, "c")
  assert restaged.boot_attempts == 0
}

test test_begin_boot_falls_back_when_another_attempt_would_exceed_max [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-attempt-cap")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let _ = activation.activation_begin_boot(state)?
  let _ = activation.activation_begin_boot(state)?
  let at_max = activation.activation_status(state)?
  assert at_max.boot_attempts == 2
  assert_pending(at_max, "b")

  match activation.activation_begin_boot(state)? {
    activation.PendingBoot(id) => assert false, id.id
    activation.FellBack(id) => assert id.id == "a"
  }
  let fallen = activation.activation_status(state)?
  assert fallen.current.id == "a"
  assert fallen.fallback.id == "a"
  assert fallen.pending == null
  assert fallen.boot_attempts == 2
  assert fallen.last_operation == "fell-back"
  match activation.activation_begin_boot(state) {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert fallen == activation.activation_status(state)?
}

test test_stage_is_not_reapplied_after_disconnect_or_while_pending [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-disconnect")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let staged = activation.activation_status(state)?
  assert staged.current.id == "a"
  assert_pending(staged, "b")
  assert staged.last_operation == "staged"

  match activation.activation_stage(state, generation("c")) {
    Ok(_) => assert false
    Err(error) => assert "already pending" in error.message
  }
  let again = activation.activation_status(state)?
  assert again.current == staged.current
  assert again.fallback == staged.fallback
  assert again.pending == staged.pending
  assert again.boot_attempts == staged.boot_attempts
  assert again.last_operation == "staged"
}

test test_confirm_rejects_the_wrong_id_and_a_boot_that_has_not_started [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-confirm-reject")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let staged = record_text(state)?
  match activation.activation_confirm_health(state, "b") {
    Ok(_) => assert false
    Err(error) => assert "has not booted" in error.message
  }
  assert record_text(state)? == staged

  let _ = activation.activation_begin_boot(state)?
  let booting = record_text(state)?
  match activation.activation_confirm_health(state, "a") {
    Ok(_) => assert false
    Err(error) => assert "does not match" in error.message
  }
  match activation.activation_confirm_health(state, "c") {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert record_text(state)? == booting
  let status = activation.activation_status(state)?
  assert status.current.id == "a"
  assert status.fallback.id == "a"
  assert_pending(status, "b")
  assert status.boot_attempts == 1
  assert status.last_operation == "pending-boot"
}

test test_tampered_pending_digest_does_not_confirm [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-tamper")?
  activation.activation_install(state, generation("a"))
  activation.activation_stage(state, generation("b"))
  let _ = activation.activation_begin_boot(state)?
  let record_file = fp"{state}/{activation.ACTIVATION_RECORD_NAME}"
  let broken = record_file.read_text()?.replace(sha256_text("b"), with: "not-a-digest")
  record_file.write(broken)
  let tampered = record_file.read_text()?
  match activation.activation_status(state) {
    Ok(_) => assert false
    Err(error) => assert "unreadable" in error.message
  }
  match activation.activation_begin_boot(state) {
    Ok(_) => assert false
    Err(_) => {}
  }
  match activation.activation_confirm_health(state, "b") {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert record_file.read_text()? == tampered
  assert "\"a\"" in tampered
  assert ! fp"{state}/{activation.ACTIVATION_LOCK_NAME}".exists()?
}

test test_abandoned_lock_fails_closed_until_release [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-lock")?
  activation.activation_install(state, generation("a"))
  let lock = fp"{state}/{activation.ACTIVATION_LOCK_NAME}"
  fs.mknod(lock, "file", 0o600)
  let before = record_text(state)?
  match activation.activation_stage(state, generation("b")) {
    Ok(_) => assert false
    Err(error) => assert "lock is held" in error.message
  }
  assert lock.exists()?
  assert record_text(state)? == before
  lock.unlink()
  activation.activation_stage(state, generation("b"))
  assert_pending(activation.activation_status(state)?, "b")
  assert ! lock.exists()?
}

test test_fresh_lock_is_not_stolen_and_a_stale_lock_expires [fs, time, error] { |ctx|
  let fresh = state_dir(ctx, "activation-lock-fresh")?
  activation.activation_install(fresh, generation("a"))
  let fresh_lock = fp"{fresh}/{activation.ACTIVATION_LOCK_NAME}"
  fs.mknod(fresh_lock, "file", 0o600)
  let before = record_text(fresh)?
  match activation.activation_stage(fresh, generation("b"), 1s) {
    Ok(_) => assert false
    Err(error) => assert "lock is held" in error.message
  }
  assert fresh_lock.exists()?
  assert record_text(fresh)? == before

  let stale = state_dir(ctx, "activation-lock-stale")?
  activation.activation_install(stale, generation("a"))
  let stale_lock = fp"{stale}/{activation.ACTIVATION_LOCK_NAME}"
  fs.mknod(stale_lock, "file", 0o600)
  fs.set_times(stale_lock, mtime_ns: 0)
  activation.activation_stage(stale, generation("b"), 1s)
  let status = activation.activation_status(stale)?
  assert status.current.id == "a"
  assert_pending(status, "b")
  assert status.last_operation == "staged"
  assert ! stale_lock.exists()?
}

test test_stage_rejects_invalid_receipts_without_mutation [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-invalid")?
  match activation.activation_install(state, {id: "a", kernel: "boot/vmlinuz-a", root_digest: "abcd"}) {
    Ok(_) => assert false
    Err(error) => assert "invalid" in error.message
  }
  assert ! fp"{state}/{activation.ACTIVATION_RECORD_NAME}".exists()?

  activation.activation_install(state, generation("a"))
  let installed = record_text(state)?
  match activation.activation_stage(state, {id: "b", kernel: "boot/vmlinuz-b", root_digest: "zz"}) {
    Ok(_) => assert false
    Err(_) => {}
  }
  match activation.activation_stage(state, {id: "b", kernel: "", root_digest: sha256_text("b")}) {
    Ok(_) => assert false
    Err(_) => {}
  }
  match activation.activation_stage(state, generation("a")) {
    Ok(_) => assert false
    Err(error) => assert "current generation" in error.message
  }
  match activation.activation_install(state, generation("c")) {
    Ok(_) => assert false
    Err(_) => {}
  }
  assert record_text(state)? == installed
}

test test_unwritable_state_directory_leaves_the_record [fs, time, error] { |ctx|
  let state = state_dir(ctx, "activation-unwritable")?
  activation.activation_install(state, generation("a"))
  let before = record_text(state)?
  state.chmod(0o555)
  defer state.chmod(0o755)
  match activation.activation_stage(state, generation("b")) {
    Ok(_) => assert false
    Err(_) => {}
  }
  state.chmod(0o755)
  assert record_text(state)? == before
  let status = activation.activation_status(state)?
  assert status.current.id == "a"
  assert status.pending == null
  assert status.last_operation == "installed"
}
