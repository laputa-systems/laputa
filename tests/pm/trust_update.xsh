##! End-to-end signed trust update: verification matrix, atomic activation,
##! recovery, concurrency, and CLI behavior on disposable system roots.
use trust.release as trust_release
use trust.store as trust_store
use trust.update as trust_update

proc fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/trust-update/{name}"
}

proc key_bytes(name: Str) -> Result[Bytes] {
  fixture(f"keys/{name}.public.base64").read_text()?.trim().base64_decode()?
}

## Stages a disposable system root with live seeds, canonical symlinks, and
## the given fixture verification key.
proc stage_system(ctx: TestContext, name: Str, key: Str) -> Result[Path, Error] {
  let root = test.temp_dir(ctx, name: name)?
  let seed_bundle = fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt"
  let seed_policy = fp"{root}/usr/share/laputa/trust/seed/trust-policy"
  let key_path = fp"{root}/etc/laputa/trust-update-key"
  for parent in [seed_bundle.parent, key_path.parent, fp"{root}/etc/ssl/certs"] {
    parent.mkdir(parents: true)
  }

  seed_bundle.write(p"packages/ca-certificates/files/cacert.pem".read_bytes()?)
  seed_policy.write(p"packages/ca-certificates/files/trust-policy".read_bytes()?)
  key_path.write(key_bytes(key)?)
  fp"{root}/etc/ssl/certs/ca-certificates.crt".symlink(to: p"../../../var/lib/laputa/trust/active/ca-certificates.crt")
  fp"{root}/etc/laputa/trust-policy".symlink(to: p"../../var/lib/laputa/trust/active/trust-policy")
  fp"{root}/etc/ssl/cert.pem".symlink(to: p"certs/ca-certificates.crt")
  root
}

## Stages a release source directory from fixtures without touching them.
proc stage_release(ctx: TestContext, name: Str, which: Str) -> Result[Path, Error] {
  let out = fp"{test.temp_dir(ctx, name: name)?}/release"
  out.mkdir(parents: true)
  for file in ["metadata", "metadata.sig", "ca-certificates.crt", "trust-policy"] {
    fp"{fixture(which)}/{file}".copy(to: fp"{out}/{file}")
  }

  out
}

proc active_bundle(root: Path) -> Result[Bytes, Error] {
  fp"{root}/var/lib/laputa/trust/active/ca-certificates.crt".read_bytes()
}

proc active_policy(root: Path) -> Result[Bytes, Error] {
  fp"{root}/var/lib/laputa/trust/active/trust-policy".read_bytes()
}

proc expect_rejected(input: Result[Record, Error], fragment: Str, root: Path, generation: Str, label: Str) [fs, error] {
  match input {
    Ok(_) => test.fail(f"{label}: invalid trust release was accepted"),
    Err(problem) => assert fragment in problem.message
  }

  if generation == "" {
    assert ! trust_store.trust_store_active_present(trust_store.trust_store_paths(root))?, label
    return
  }

  assert trust_store.trust_store_read_active(trust_store.trust_store_paths(root))? == generation
}

## Captures the observable store state for zero-mutation assertions.
proc snapshot_store_state(paths: trust_store.TrustStorePaths) [fs, error] -> Result[Record, Error] {
  var generations: List[Str] = []
  for entry in fs.children(paths.generations)? {
    generations += [entry.name]
  }
  generations = generations |> sort

  var staging: List[Str] = []
  if paths.staging.exists()? {
    for entry in fs.children(paths.staging)? {
      staging += [entry.name]
    }
  }
  staging = staging |> sort

  {
    accepted: paths.accepted.read_bytes()?,
    journal: if paths.journal.exists()? { paths.journal.read_bytes()? } else { bytes.from_text("") },
    journal_present: paths.journal.exists()?,
    active: trust_store.trust_store_read_active(paths)?,
    generations,
    staging,
  }
}

proc assert_same_store_state(before: Record, after: Record, label: Str) [error] {
  assert before.accepted.require(Bytes)? == after.accepted.require(Bytes)?, label
  assert before.journal.require(Bytes)? == after.journal.require(Bytes)?, label
  assert before.journal_present.require(Bool)? == after.journal_present.require(Bool)?, label
  assert before.active.require(Str)? == after.active.require(Str)?, label
  assert before.generations.require(List[Str])? == after.generations.require(List[Str])?, label
  assert before.staging.require(List[Str])? == after.staging.require(List[Str])?, label
}

test trust_status_reports_uninitialized_system [fs, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "trust-status-empty")?
  let status = trust_update.trust_status(root)?
  assert status.initialized == false
}

test trust_update_bootstraps_and_applies_release [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-happy", "signing-key")?
  let source = stage_release(ctx, "trust-update-happy-source", "release-b")?
  let before = trust_update.trust_status(root)?
  assert before.initialized == false

  let applied = trust_update.trust_update_from_dir(root, source)?
  assert applied.generation == "2"
  assert applied.bundle_sha256 == fixture("release-b/ca-certificates.crt").read_bytes()?.sha256().hex()
  assert applied.policy_sha256 == fixture("release-b/trust-policy").read_bytes()?.sha256().hex()

  let after = trust_update.trust_status(root)?
  assert after.generation == "2"
  assert after.accepted == "2"
  assert after.pending == "none"
  assert after.freshness != "EXPIRED"
  assert active_bundle(root)? == fixture("release-b/ca-certificates.crt").read_bytes()?
  assert active_policy(root)? == fixture("release-b/trust-policy").read_bytes()?
  assert fp"{root}/var/lib/laputa/trust/generations/2/metadata".read_bytes()? == fixture("release-b/metadata").read_bytes()?
}

test trust_update_reapplies_identical_release_as_noop [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-resume", "signing-key")?
  let first = stage_release(ctx, "trust-update-resume-a", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, first)?
  let second = stage_release(ctx, "trust-update-resume-b", "release-b")?
  let resumed = trust_update.trust_update_from_dir(root, second)?
  assert resumed.generation == "2"
  let status = trust_update.trust_status(root)?
  assert status.generation == "2"
  assert status.pending == "none"
}

test trust_update_rejects_stale_and_conflicting_releases [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-stale", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-stale-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?

  let stale = stage_release(ctx, "trust-update-stale-a", "release-a-stale")?
  expect_rejected(trust_update.trust_update_from_dir(root, stale), "does not advance", root, "2", "stale")

  let conflict = stage_release(ctx, "trust-update-stale-conflict", "release-b")?
  fp"{conflict}/trust-policy".write(bytes.from_text("tampered policy\n"))
  match trust_update.trust_update_from_dir(root, conflict) {
    Ok(_) => test.fail("conflicting release for the active generation was accepted"),
    Err(problem) => assert "conflicting trust policy for active generation" in problem.message
  }

  assert active_bundle(root)? == fixture("release-b/ca-certificates.crt").read_bytes()?
}

test trust_update_rejects_bad_signatures_and_keys [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-signer", "signing-key")?
  let wrong = stage_release(ctx, "trust-update-wrong", "release-b-wrongsigned")?
  expect_rejected(trust_update.trust_update_from_dir(root, wrong), "signature is invalid", root, "1", "wrong-signer")

  let tampered = stage_release(ctx, "trust-update-tampered", "release-b")?
  let tampered_text = fp"{tampered}/metadata".read_text()?.replace("generation 2", with: "generation 9")
  fp"{tampered}/metadata".write(bytes.from_text(tampered_text))
  match trust_update.trust_update_from_dir(root, tampered) {
    Ok(_) => test.fail("tampered metadata was accepted"),
    Err(problem) => assert "signature is invalid" in problem.message
  }

  let unkeyed = test.temp_dir(ctx, name: "trust-update-unkeyed")?
  let seed_bundle = fp"{unkeyed}/usr/share/laputa/trust/seed/ca-certificates.crt"
  let seed_policy = fp"{unkeyed}/usr/share/laputa/trust/seed/trust-policy"
  seed_bundle.parent.mkdir(parents: true)
  fp"{unkeyed}/etc/laputa".mkdir(parents: true)
  fp"{unkeyed}/etc/ssl/certs".mkdir(parents: true)
  seed_bundle.write(p"packages/ca-certificates/files/cacert.pem".read_bytes()?)
  seed_policy.write(p"packages/ca-certificates/files/trust-policy".read_bytes()?)
  fp"{unkeyed}/etc/ssl/certs/ca-certificates.crt".symlink(to: p"../../../var/lib/laputa/trust/active/ca-certificates.crt")
  fp"{unkeyed}/etc/laputa/trust-policy".symlink(to: p"../../var/lib/laputa/trust/active/trust-policy")
  let source = stage_release(ctx, "trust-update-unkeyed-source", "release-b")?
  match trust_update.trust_update_from_dir(unkeyed, source) {
    Ok(_) => test.fail("unprovisioned trust update was accepted"),
    Err(problem) => assert "provisioned" in problem.message
  }

  assert ! fp"{unkeyed}/var/lib/laputa/trust".exists()?
}

test trust_update_rejects_wrong_length_key [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-short-key", "signing-key")?
  fp"{root}/etc/laputa/trust-update-key".write(bytes.from_text("short"))
  let source = stage_release(ctx, "trust-update-short-key-source", "release-b")?
  expect_rejected(trust_update.trust_update_from_dir(root, source), "exactly 32 raw Ed25519 bytes", root, "", "short-key")
}

test trust_update_rejects_expired_and_overlong_releases [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-expiry", "signing-key")?
  let expired = stage_release(ctx, "trust-update-expired", "release-expired")?
  expect_rejected(trust_update.trust_update_from_dir(root, expired), "has expired", root, "1", "expired")

  let far = fixture("release-too-far")
  let metadata = fp"{far}/metadata".read_bytes()?
  let expiry = trust_release.release_parse_metadata(metadata)?.expires_at
  let input = {
    metadata,
    signature: fp"{far}/metadata.sig".read_bytes()?,
    provisioned_public_key: key_bytes("signing-key")?,
    root_bundle: fp"{far}/ca-certificates.crt".read_bytes()?,
    next_policy: fp"{far}/trust-policy".read_bytes()?,
    installed_policy_snapshot: fp"{root}/usr/share/laputa/trust/seed/trust-policy".read_bytes()?,
    now_epoch_seconds: expiry - 7776001,
  }
  match trust_release.release_verify(input) {
    Ok(_) => test.fail("overlong signed release was accepted"),
    Err(problem) => assert "90-day" in problem.message
  }
  let _ = trust_release.release_verify({...input, now_epoch_seconds: expiry - 7776000})?
}

test trust_update_rejects_unparseable_seed_bundle [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-bad-seed", "signing-key")?
  fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt".write(bytes.from_text("not a bundle\n"))
  let source = stage_release(ctx, "trust-update-bad-seed-source", "release-b")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("trust update bootstrapped from an unparseable seed bundle"),
    Err(problem) => assert "no certificates" in problem.message
  }

  assert ! fp"{root}/var/lib/laputa/trust/generations".exists()?
}

test trust_update_rejects_oversized_payloads [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-oversized", "signing-key")?
  let big_bundle = stage_release(ctx, "trust-update-big-bundle", "release-b")?
  var padding = ""
  for _ in range(33000) { padding += "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  fp"{big_bundle}/ca-certificates.crt".write(bytes.from_text(fp"{big_bundle}/ca-certificates.crt".read_text()? + padding))
  expect_rejected(trust_update.trust_update_from_dir(root, big_bundle), "release file exceeds its size bound", root, "", "oversized-bundle")

  let big_policy = stage_release(ctx, "trust-update-big-policy", "release-b")?
  var policy_padding = ""
  for _ in range(30000) { policy_padding += "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }
  fp"{big_policy}/trust-policy".write(bytes.from_text(fp"{big_policy}/trust-policy".read_text()? + policy_padding))
  expect_rejected(trust_update.trust_update_from_dir(root, big_policy), "release file exceeds its size bound", root, "", "oversized-policy")
}

test trust_update_rejects_malformed_releases [fs, process, env, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-malformed", "signing-key")?
  let base = stage_release(ctx, "trust-update-malformed-base", "release-b")?

  var big = ""
  for _ in range(4097) { big += "x" }
  let oversized = stage_release(ctx, "trust-update-oversized", "release-b")?
  fp"{oversized}/metadata".write(bytes.from_text(big))
  expect_rejected(trust_update.trust_update_from_dir(root, oversized), "release file exceeds its size bound", root, "", "oversized-metadata")

  let bad_bundle = stage_release(ctx, "trust-update-bad-bundle", "release-b")?
  fp"{bad_bundle}/ca-certificates.crt".write(bytes.from_text("not a bundle\n"))
  expect_rejected(trust_update.trust_update_from_dir(root, bad_bundle), "root bundle digest", root, "1", "malformed-bundle")

  let bad_policy = stage_release(ctx, "trust-update-bad-policy", "release-b")?
  fp"{bad_policy}/trust-policy".write(bytes.from_text("laputa-trust-policy-v1\ngeneration 2\nunknown-field x\n"))
  expect_rejected(trust_update.trust_update_from_dir(root, bad_policy), "unknown or malformed", root, "1", "malformed-policy")

  let linked = stage_release(ctx, "trust-update-linked", "release-b")?
  let outside = test.temp_path(ctx, name: "trust-update-linked-outside")
  outside.write(bytes.from_text("not a release\n"))?
  fp"{linked}/metadata".remove()?
  fp"{linked}/metadata".symlink(to: outside)?
  expect_rejected(trust_update.trust_update_from_dir(root, linked), "not a regular file", root, "1", "symlinked-metadata")

  let duped = stage_release(ctx, "trust-update-duped", "release-b")?
  fp"{duped}/trust-policy".write(bytes.from_text("laputa-trust-policy-v1\ngeneration 2\nblocked-spki-sha256 0000000000000000000000000000000000000000000000000000000000000000\nblocked-spki-sha256 0000000000000000000000000000000000000000000000000000000000000000\n"))
  expect_rejected(trust_update.trust_update_from_dir(root, duped), "repeats a blocked SPKI", root, "1", "duplicate-spki")
}

test trust_update_rejects_digest_mismatches [fs, process, env, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-digests", "signing-key")?
  let bundle = stage_release(ctx, "trust-update-digest-bundle", "release-b")?
  fp"{bundle}/ca-certificates.crt".write(bytes.from_text(fp"{bundle}/ca-certificates.crt".read_text()? + "extra\n"))
  expect_rejected(trust_update.trust_update_from_dir(root, bundle), "root bundle digest", root, "1", "bundle-digest")

  let policy = stage_release(ctx, "trust-update-digest-policy", "release-b")?
  fp"{policy}/trust-policy".write(bytes.from_text(fp"{policy}/trust-policy".read_text()? + "blocked-spki-sha256 0000000000000000000000000000000000000000000000000000000000000000\n"))
  expect_rejected(trust_update.trust_update_from_dir(root, policy), "trust policy digest", root, "1", "policy-digest")

  let generation = stage_release(ctx, "trust-update-digest-generation", "release-b")?
  let other = stage_release(ctx, "trust-update-digest-other", "release-c")?
  fp"{generation}/trust-policy".write(fp"{other}/trust-policy".read_bytes()?)
  expect_rejected(trust_update.trust_update_from_dir(root, generation), "does not match signed metadata", root, "1", "policy-generation")
}

test trust_update_advances_generations_and_removes_old_roots [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-advance", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-advance-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  let release_c = stage_release(ctx, "trust-update-advance-c", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, release_c)?
  assert applied.generation == "3"

  let bundle = active_bundle(root)?
  assert bundle == fixture("release-c/ca-certificates.crt").read_bytes()?
  let policy = active_policy(root)?
  assert policy == fixture("release-c/trust-policy").read_bytes()?

  let status = trust_update.trust_status(root)?
  assert status.generation == "3"
  assert status.accepted == "3"
  assert status.pending == "none"
}

test trust_update_serializes_concurrent_attempts [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-concurrent", "signing-key")?
  let source = stage_release(ctx, "trust-update-concurrent-source", "release-b")?
  let paths = trust_store.trust_store_paths(root)
  let held = trust_store.trust_store_take_lock(paths)?

  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("concurrent trust update was admitted"),
    Err(problem) => assert "another trust update holds the store lock" in problem.message
  }

  assert ! fp"{root}/var/lib/laputa/trust/generations".exists()?
  fs.unlock(held)?
  let applied = trust_update.trust_update_from_dir(root, source)?
  assert applied.generation == "2"
}

test trust_update_never_replaces_an_existing_generation [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-conflict", "signing-key")?
  let blocker = fp"{root}/var/lib/laputa/trust/generations/2"
  blocker.parent.mkdir(parents: true)
  blocker.mkdir()
  fp"{blocker}/sentinel".write("foreign generation\n")

  let source = stage_release(ctx, "trust-update-conflict-source", "release-b")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("trust update replaced an existing generation"),
    Err(problem) => assert "already installed; refusing to bootstrap seeds over it" in problem.message
  }

  assert fp"{blocker}/sentinel".read_text()? == "foreign generation\n"
  assert ! fp"{root}/var/lib/laputa/trust/active".exists()?
  assert ! fp"{root}/var/lib/laputa/trust/accepted".exists()?
  assert ! fp"{root}/var/lib/laputa/trust/generations/1".exists()?

  blocker.remove()?
  let release_c = stage_release(ctx, "trust-update-conflict-c", "release-c")?
  match trust_update.trust_update_from_dir(root, release_c) {
    Ok(applied) => assert applied.generation == "3"
    Err(problem) => test.fail(f"update failed after removing the foreign generation: {problem.message}")
  }

  assert fp"{blocker}/sentinel".exists()? == false
}

test trust_update_rejects_releases_behind_the_time_lower_bound [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-clock", "signing-key")?
  let source = stage_release(ctx, "trust-update-clock-source", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, source)?

  let paths = trust_store.trust_store_paths(root)
  trust_store.trust_store_persist_lower_bound(paths, time.now() / 1000 + 100000)?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("trust update accepted a release behind the persisted time bound"),
    Err(problem) => assert "system clock reads behind" in problem.message
  }

  assert trust_store.trust_store_read_active(paths)? == "2"
}

test trust_update_persists_a_monotonic_time_lower_bound [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-clock-persist", "signing-key")?
  let source = stage_release(ctx, "trust-update-clock-persist-source", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, source)?

  let paths = trust_store.trust_store_paths(root)
  let first = trust_store.trust_store_read_lower_bound(paths)?
  assert first > 0

  let _ = trust_update.trust_update_from_dir(root, source)?
  let second = trust_store.trust_store_read_lower_bound(paths)?
  assert second >= first
}

test trust_update_recovers_interrupted_staging [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-recover-stage", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-recover-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?

  let paths = trust_store.trust_store_paths(root)
  let staging = "staging/candidate-3-orphan"
  fp"{paths.store}/{staging}".mkdir(parents: true)
  fp"{paths.store}/{staging}/owner".write(bytes.from_text("orphan-token"))
  let key = key_bytes("signing-key")?
  trust_store.trust_store_write_journal(paths, "staged", "3", staging, "orphan-token")?

  let source = stage_release(ctx, "trust-update-recover-c", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, source)?
  assert applied.generation == "3"
  assert ! fp"{paths.store}/{staging}".exists()?
  let journal = trust_store.trust_store_read_journal(paths)?
  assert journal.present == false
}

test trust_update_rolls_forward_a_committed_candidate [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-recover-commit", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-recover-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?

  let paths = trust_store.trust_store_paths(root)
  let key = key_bytes("signing-key")?
  let bundle = fixture("release-c/ca-certificates.crt").read_bytes()?
  let policy = fixture("release-c/trust-policy").read_bytes()?
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    "3",
    bundle,
    policy,
    fixture("release-c/metadata").read_bytes()?,
    fixture("release-c/metadata.sig").read_bytes()?,
  )?
  trust_store.trust_store_write_journal(paths, "committed", "3", staged.path, staged.token)?
  trust_store.trust_store_commit_generation(paths, staged.path, "3")?

  let applied = trust_update.trust_update_from_dir(root, stage_release(ctx, "trust-update-recover-c", "release-c")?)?
  assert applied.generation == "3"
  assert trust_store.trust_store_read_active(paths)? == "3"
  assert active_bundle(root)? == bundle
}

test trust_update_refuses_unknown_journal_state [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-unknown", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-unknown-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?

  let paths = trust_store.trust_store_paths(root)
  json.write(paths.journal, {format: "other", phase: 7})?
  let source = stage_release(ctx, "trust-update-unknown-c", "release-c")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("trust update proceeded with an unknown journal"),
    Err(problem) => assert "unreadable" in problem.message
  }

  assert trust_store.trust_store_read_active(paths)? == "2"
  assert active_bundle(root)? == fixture("release-b/ca-certificates.crt").read_bytes()?
}

test trust_bootstrap_refuses_over_accepted_generation_without_mutation [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-bootstrap-downgrade", "signing-key")?
  let release_b = stage_release(ctx, "trust-bootstrap-downgrade-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  fp"{root}/var/lib/laputa/trust/active".remove()?

  match trust_store.trust_store_bootstrap_from_seeds(root) {
    Ok(_) => test.fail("bootstrap activated generation 1 over accepted generation 2"),
    Err(_) => {},
  }

  assert ! fp"{root}/var/lib/laputa/trust/active".exists()?
  assert trust_store.trust_store_read_accepted(trust_store.trust_store_paths(root))? == "2"
}

test trust_bootstrap_refuses_dangling_active_without_mutation [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-bootstrap-dangling", "signing-key")?
  let release_b = stage_release(ctx, "trust-bootstrap-dangling-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  fp"{root}/var/lib/laputa/trust/active".remove()?
  fp"{root}/var/lib/laputa/trust/active".symlink(to: p"generations/9")?

  match trust_store.trust_store_bootstrap_from_seeds(root) {
    Ok(_) => test.fail("bootstrap activated generation 1 over a dangling active pointer"),
    Err(_) => {},
  }

  assert fp"{root}/var/lib/laputa/trust/active".readlink()? == p"generations/9"
  assert trust_store.trust_store_read_accepted(trust_store.trust_store_paths(root))? == "2"
}

test trust_update_repairs_lost_active_pointer_without_downgrade [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-repair", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-repair-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  fp"{root}/var/lib/laputa/trust/active".remove()?

  let release_c = stage_release(ctx, "trust-update-repair-c", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, release_c)?
  assert applied.generation == "3"
  assert trust_store.trust_store_read_active(trust_store.trust_store_paths(root))? == "3"
  assert trust_store.trust_store_read_accepted(trust_store.trust_store_paths(root))? == "3"
}

test trust_status_reports_seed_provenance_after_bootstrap [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-status-seed", "signing-key")?
  let generation = trust_store.trust_store_bootstrap_from_seeds(root)?
  assert generation == "1"
  let status = trust_update.trust_status(root)?
  assert status.generation == "1"
  assert status.accepted == "1"
  assert status.provenance == "package-seed"
  assert status.pending == "none"
  assert status.freshness == "seed (no signed expiry; apply a signed release)"
}

test trust_status_reports_signed_provenance_after_update [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-status-signed", "signing-key")?
  let _ = trust_store.trust_store_bootstrap_from_seeds(root)?
  let source = stage_release(ctx, "trust-status-signed-source", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, source)?
  let status = trust_update.trust_status(root)?
  assert status.generation == "2"
  assert status.provenance == "signed-release"
  assert status.expires_at.require(Int)? > 0
}

test trust_update_adopts_orphaned_commit_after_staged_journal [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-adopt", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-adopt-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?

  let paths = trust_store.trust_store_paths(root)
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    "3",
    fixture("release-c/ca-certificates.crt").read_bytes()?,
    fixture("release-c/trust-policy").read_bytes()?,
    fixture("release-c/metadata").read_bytes()?,
    fixture("release-c/metadata.sig").read_bytes()?,
  )?
  trust_store.trust_store_write_journal(paths, "staged", "3", staged.path, staged.token)?
  trust_store.trust_store_commit_generation(paths, staged.path, "3")?

  let applied = trust_update.trust_update_from_dir(root, stage_release(ctx, "trust-update-adopt-c", "release-c")?)?
  assert applied.generation == "3"
  assert trust_store.trust_store_read_active(paths)? == "3"
  assert trust_store.trust_store_read_accepted(paths)? == "3"
  let journal = trust_store.trust_store_read_journal(paths)?
  assert journal.present == false
}

test trust_update_refuses_expired_commit_and_cleans_up [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-expired-commit", "signing-key")?
  let _ = trust_store.trust_store_bootstrap_from_seeds(root)?

  let paths = trust_store.trust_store_paths(root)
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    "2",
    fixture("release-expired/ca-certificates.crt").read_bytes()?,
    fixture("release-expired/trust-policy").read_bytes()?,
    fixture("release-expired/metadata").read_bytes()?,
    fixture("release-expired/metadata.sig").read_bytes()?,
  )?
  trust_store.trust_store_write_journal(paths, "committed", "2", staged.path, staged.token)?
  trust_store.trust_store_commit_generation(paths, staged.path, "2")?

  let source = stage_release(ctx, "trust-update-expired-commit-c", "release-c")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("expired committed candidate was activated"),
    Err(problem) => assert "expired" in problem.message
  }

  assert ! fp"{paths.store}/{staged.path}".exists()?
  let journal = trust_store.trust_store_read_journal(paths)?
  assert journal.present == false
  assert trust_store.trust_store_read_active(paths)? == "1"
  assert trust_store.trust_store_read_accepted(paths)? == "1"

  let followup = stage_release(ctx, "trust-update-expired-commit-retry", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, followup)?
  assert applied.generation == "3"
}

test trust_update_rolls_forward_expired_active_without_bricking [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-expired-active", "signing-key")?
  let _ = trust_store.trust_store_bootstrap_from_seeds(root)?

  let paths = trust_store.trust_store_paths(root)
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    "2",
    fixture("release-expired/ca-certificates.crt").read_bytes()?,
    fixture("release-expired/trust-policy").read_bytes()?,
    fixture("release-expired/metadata").read_bytes()?,
    fixture("release-expired/metadata.sig").read_bytes()?,
  )?
  trust_store.trust_store_commit_generation(paths, staged.path, "2")?
  trust_store.trust_store_flip_active(paths, "2")?
  trust_store.trust_store_write_journal(paths, "activated", "2", "", staged.token)?

  let source = stage_release(ctx, "trust-update-expired-active-c", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, source)?
  assert applied.generation == "3"
  assert trust_store.trust_store_read_accepted(paths)? == "3"
  assert trust_store.trust_store_read_lower_bound(paths)? > 0
  let journal = trust_store.trust_store_read_journal(paths)?
  assert journal.present == false
}

test trust_update_finishes_flip_lagging_commit_journal [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-flip-lag", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-flip-lag-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?

  let paths = trust_store.trust_store_paths(root)
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    "3",
    fixture("release-c/ca-certificates.crt").read_bytes()?,
    fixture("release-c/trust-policy").read_bytes()?,
    fixture("release-c/metadata").read_bytes()?,
    fixture("release-c/metadata.sig").read_bytes()?,
  )?
  trust_store.trust_store_write_journal(paths, "committed", "3", staged.path, staged.token)?
  trust_store.trust_store_commit_generation(paths, staged.path, "3")?
  trust_store.trust_store_flip_active(paths, "3")?

  let applied = trust_update.trust_update_from_dir(root, stage_release(ctx, "trust-update-flip-lag-c", "release-c")?)?
  assert applied.generation == "3"
  assert trust_store.trust_store_read_accepted(paths)? == "3"
  assert ! fp"{paths.store}/{staged.path}".exists()?
  let journal = trust_store.trust_store_read_journal(paths)?
  assert journal.present == false
}

test trust_update_rotates_keys_package_only [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-rotation", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-rotation-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  let release_c = stage_release(ctx, "trust-update-rotation-c", "release-c")?
  let _ = trust_update.trust_update_from_dir(root, release_c)?
  assert trust_store.trust_store_read_active(trust_store.trust_store_paths(root))? == "3"

  var names: List[Str] = []
  for entry in fs.children(fixture("release-d"))? {
    names += [entry.name]
  }

  assert names.len() == 4
  for expected in ["metadata", "metadata.sig", "ca-certificates.crt", "trust-policy"] {
    assert expected in names
  }

  let release_text = fixture("release-d/metadata").read_text()?
  assert release_text.ends_with("\n") and "\r" not in release_text
  assert release_text.byte_slice(0, release_text.byte_len() - 1).split("\n").len() == 5
  assert "generation 4" in release_text

  let early_rotated = stage_release(ctx, "trust-update-rotation-early", "release-d")?
  expect_rejected(trust_update.trust_update_from_dir(root, early_rotated), "signature is invalid", root, "3", "rotated-before-package-update")

  fp"{root}/etc/laputa/trust-update-key".write(key_bytes("rotation-key")?)
  fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt".write(fixture("release-d/ca-certificates.crt").read_bytes()?)
  fp"{root}/usr/share/laputa/trust/seed/trust-policy".write(fixture("release-d/trust-policy").read_bytes()?)
  assert fp"{root}/etc/laputa/trust-update-key".read_bytes()? == fixture("keys/rotation-key.public.base64").read_text()?.trim().base64_decode()?
  assert fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt".read_bytes()? == fixture("release-d/ca-certificates.crt").read_bytes()?
  assert fp"{root}/usr/share/laputa/trust/seed/trust-policy".read_bytes()? == fixture("release-d/trust-policy").read_bytes()?

  let replay_old = stage_release(ctx, "trust-update-rotation-replay", "release-c")?
  expect_rejected(trust_update.trust_update_from_dir(root, replay_old), "signature", root, "3", "superseded-resume")

  let release_d = stage_release(ctx, "trust-update-rotation-d", "release-d")?
  let checked = trust_update.trust_verify(root, release_d)?
  assert checked.generation == "4"
  let applied = trust_update.trust_update_from_dir(root, release_d)?
  assert applied.generation == "4"
  assert applied.bundle_sha256 == fixture("release-d/ca-certificates.crt").read_bytes()?.sha256().hex()
  assert applied.policy_sha256 == fixture("release-d/trust-policy").read_bytes()?.sha256().hex()
  assert active_bundle(root)? == fixture("release-d/ca-certificates.crt").read_bytes()?
  assert active_policy(root)? == fixture("release-d/trust-policy").read_bytes()?

  let after = trust_update.trust_status(root)?
  assert after.generation == "4"
  assert after.accepted == "4"
  assert after.pending == "none"
  assert after.provenance == "signed-release"

  let superseded_c = stage_release(ctx, "trust-update-rotation-old-c", "release-c")?
  expect_rejected(trust_update.trust_update_from_dir(root, superseded_c), "does not advance", root, "4", "superseded-c")
  let superseded_b = stage_release(ctx, "trust-update-rotation-old-b", "release-b")?
  expect_rejected(trust_update.trust_update_from_dir(root, superseded_b), "does not advance", root, "4", "superseded-b")
  assert active_bundle(root)? == fixture("release-d/ca-certificates.crt").read_bytes()?
}

test trust_store_persist_accepted_is_monotonic [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-accepted-mono", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-accepted-mono-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  let release_c = stage_release(ctx, "trust-update-accepted-mono-c", "release-c")?
  let _ = trust_update.trust_update_from_dir(root, release_c)?

  let paths = trust_store.trust_store_paths(root)
  assert trust_store.trust_store_read_accepted(paths)? == "3"

  trust_store.trust_store_persist_accepted(paths, "3")?
  assert trust_store.trust_store_read_accepted(paths)? == "3"

  match trust_store.trust_store_persist_accepted(paths, "2") {
    Ok(_) => test.fail("accepted generation rolled back from 3 to 2"),
    Err(problem) => assert "roll back" in problem.message
  }

  assert trust_store.trust_store_read_accepted(paths)? == "3"
  assert trust_store.trust_store_read_active(paths)? == "3"
  assert active_bundle(root)? == fixture("release-c/ca-certificates.crt").read_bytes()?
}

test trust_update_rejects_stale_staged_journal_without_mutation [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-stale-staged", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-stale-staged-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  let release_c = stage_release(ctx, "trust-update-stale-staged-c", "release-c")?
  let _ = trust_update.trust_update_from_dir(root, release_c)?

  let paths = trust_store.trust_store_paths(root)
  let staging = "staging/candidate-2-stale"
  fp"{paths.store}/{staging}".mkdir(parents: true)
  fp"{paths.store}/{staging}/owner".write(bytes.from_text("stale-token"))
  trust_store.trust_store_write_journal(paths, "staged", "2", staging, "stale-token")?
  let before = snapshot_store_state(paths)?

  let source = stage_release(ctx, "trust-update-stale-staged-new", "release-c")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("stale generation-2 journal was recovered over accepted generation 3"),
    Err(problem) => assert "behind accepted generation" in problem.message
  }

  let after = snapshot_store_state(paths)?
  assert_same_store_state(before, after, "stale-staged")?
  assert fp"{paths.store}/{staging}/owner".read_bytes()? == bytes.from_text("stale-token")
  assert active_bundle(root)? == fixture("release-c/ca-certificates.crt").read_bytes()?
}

test trust_update_rejects_stale_committed_journal_without_mutation [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-stale-committed", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-stale-committed-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?
  let release_c = stage_release(ctx, "trust-update-stale-committed-c", "release-c")?
  let _ = trust_update.trust_update_from_dir(root, release_c)?

  let paths = trust_store.trust_store_paths(root)
  assert trust_store.trust_store_generation_dir(paths, "2").exists()?
  trust_store.trust_store_write_journal(paths, "committed", "2", "staging/candidate-2-gone", "stale-token")?
  let before = snapshot_store_state(paths)?

  let source = stage_release(ctx, "trust-update-stale-committed-new", "release-c")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("stale generation-2 journal was recovered over accepted generation 3"),
    Err(problem) => assert "behind accepted generation" in problem.message
  }

  let after = snapshot_store_state(paths)?
  assert_same_store_state(before, after, "stale-committed")?
  assert active_bundle(root)? == fixture("release-c/ca-certificates.crt").read_bytes()?
}

test trust_update_refuses_expired_staged_adoption_without_activation [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-expired-adopt", "signing-key")?
  let _ = trust_store.trust_store_bootstrap_from_seeds(root)?

  let paths = trust_store.trust_store_paths(root)
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    "2",
    fixture("release-expired/ca-certificates.crt").read_bytes()?,
    fixture("release-expired/trust-policy").read_bytes()?,
    fixture("release-expired/metadata").read_bytes()?,
    fixture("release-expired/metadata.sig").read_bytes()?,
  )?
  trust_store.trust_store_write_journal(paths, "staged", "2", staged.path, staged.token)?
  trust_store.trust_store_commit_generation(paths, staged.path, "2")?

  let source = stage_release(ctx, "trust-update-expired-adopt-c", "release-c")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("expired committed-but-never-activated release was adopted"),
    Err(problem) => assert "expired" in problem.message
  }

  assert trust_store.trust_store_read_active(paths)? == "1"
  assert trust_store.trust_store_read_accepted(paths)? == "1"
  assert ! fp"{paths.store}/{staged.path}".exists()?
  let journal = trust_store.trust_store_read_journal(paths)?
  assert journal.present == false

  let followup = stage_release(ctx, "trust-update-expired-adopt-retry", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, followup)?
  assert applied.generation == "3"
  assert trust_store.trust_store_read_accepted(paths)? == "3"
}

test trust_update_staged_adoption_preserves_activated_release_after_expiry [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-adopted-expired", "signing-key")?
  let _ = trust_store.trust_store_bootstrap_from_seeds(root)?

  let paths = trust_store.trust_store_paths(root)
  let staged = trust_store.trust_store_stage_candidate(
    paths,
    "2",
    fixture("release-expired/ca-certificates.crt").read_bytes()?,
    fixture("release-expired/trust-policy").read_bytes()?,
    fixture("release-expired/metadata").read_bytes()?,
    fixture("release-expired/metadata.sig").read_bytes()?,
  )?
  trust_store.trust_store_write_journal(paths, "staged", "2", staged.path, staged.token)?
  trust_store.trust_store_commit_generation(paths, staged.path, "2")?
  trust_store.trust_store_flip_active(paths, "2")?

  let source = stage_release(ctx, "trust-update-adopted-expired-c", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, source)?
  assert applied.generation == "3"
  assert trust_store.trust_store_read_active(paths)? == "3"
  assert trust_store.trust_store_read_accepted(paths)? == "3"
  let journal = trust_store.trust_store_read_journal(paths)?
  assert journal.present == false
}

test trust_update_refuses_torn_journal_write_without_mutation [fs, process, time, error] { |ctx|
  let root = stage_system(ctx, "trust-update-torn-journal", "signing-key")?
  let release_b = stage_release(ctx, "trust-update-torn-journal-b", "release-b")?
  let _ = trust_update.trust_update_from_dir(root, release_b)?

  let paths = trust_store.trust_store_paths(root)
  let before = snapshot_store_state(paths)?
  assert before.journal_present.require(Bool)? == false
  let torn = bytes.from_text("{\"format\": \"laputa-trust-journal-1\", \"phase\": \"commit")
  paths.journal.write(torn)?

  let source = stage_release(ctx, "trust-update-torn-journal-c", "release-c")?
  match trust_update.trust_update_from_dir(root, source) {
    Ok(_) => test.fail("torn journal write was recovered"),
    Err(problem) => assert "unreadable" in problem.message
  }

  assert trust_store.trust_store_read_active(paths)? == "2"
  assert trust_store.trust_store_read_accepted(paths)? == "2"
  assert active_bundle(root)? == fixture("release-b/ca-certificates.crt").read_bytes()?
  assert paths.journal.read_bytes()? == torn
}
