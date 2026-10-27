##! End-to-end signed trust update: verification matrix, atomic activation,
##! recovery, concurrency, and CLI behavior on disposable system roots.
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
  assert after.atomic_capable == true
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

  let far = stage_release(ctx, "trust-update-far", "release-too-far")?
  expect_rejected(trust_update.trust_update_from_dir(root, far), "90-day", root, "1", "too-far")
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
    Err(problem) => assert "immutable trust generation already exists" in problem.message
  }

  assert fp"{blocker}/sentinel".read_text()? == "foreign generation\n"
  assert trust_store.trust_store_read_active(trust_store.trust_store_paths(root))? == "1"

  let release_c = stage_release(ctx, "trust-update-conflict-c", "release-c")?
  let applied = trust_update.trust_update_from_dir(root, release_c)?
  assert applied.generation == "3"
  assert fp"{blocker}/sentinel".read_text()? == "foreign generation\n"
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
