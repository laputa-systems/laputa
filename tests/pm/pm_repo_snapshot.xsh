##! Behavior coverage for versioned signed repository snapshots: format,
##! verification, rotation, expiry, rollback/freeze handling, size limits,
##! atomic publication, and the verified production fetch path.
use pm.remote
use pm.repo
use pm.repo_snapshot
use pm.util as pm_util

pure fixture(name: Str) -> Path {
  fp"tests/pm/fixtures/repo-snapshot/{name}"
}

pure reference_now() -> Int {
  1995000000
}

pure reference_expires() -> Int {
  2000000000
}

pure reference_digest() -> Str {
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

proc runner() [fs, process, env, error] -> Result[Path] {
  let configured = (e"XSH_HOST" ?? "").trim()

  return path.absolute(fp"{configured}")? when configured != ""

  process.which("xsh")?
}

proc key_bytes(name: Str) -> Result[Bytes] {
  fixture(f"keys/{name}.public.base64").read_text()?.trim().base64_decode()?
}

proc snapshot_bytes(which: Str, name: Str) -> Result[Bytes] {
  fixture(f"{which}/{name}").read_bytes()?
}

proc verify_input(keys: List[Bytes], accepted: repo_snapshot.SnapshotAccepted?) -> Result[repo_snapshot.SnapshotVerifyInput, Error] {
  {
    metadata: snapshot_bytes("snapshot-gen1", "metadata")?,
    signature: snapshot_bytes("snapshot-gen1", "metadata.sig")?,
    keys,
    index_bytes: fixture("index.json").read_bytes()?,
    accepted,
    now_epoch_seconds: reference_now(),
  }
}

proc expect_snapshot_rejected(input: repo_snapshot.SnapshotVerifyInput, fragment: Str) {
  match repo_snapshot.snapshot_verify(input) {
    Ok(_) => test.fail(f"invalid repository snapshot was accepted: {fragment}"),
    Err(problem) => assert fragment in problem.message
  }
}

test test_snapshot_metadata_constructor_parses_and_round_trips [fs, error] { |_|
  let text = repo_snapshot.snapshot_metadata_text("7", reference_expires(), reference_digest())
  let parsed = repo_snapshot.snapshot_parse_metadata(bytes.from_text(text))?

  assert parsed.generation == "7"
  assert parsed.expires_at == reference_expires()
  assert parsed.index_sha256 == reference_digest()
}

test test_snapshot_verify_accepts_fixture_generation [fs, error] { |_|
  let verified = repo_snapshot.snapshot_verify(verify_input([key_bytes("signing-key")?], null)?)?

  assert verified.generation == "1"
  assert verified.expires_at == reference_expires()
  assert verified.index_sha256 == fixture("index.json").read_bytes()?.sha256().hex()
}

test test_snapshot_verify_accepts_rotation_window_and_rejects_superseded_keys [fs, error] { |_|
  let gen2 = {
    metadata: snapshot_bytes("snapshot-gen2", "metadata")?,
    signature: snapshot_bytes("snapshot-gen2", "metadata.sig")?,
    keys: [key_bytes("signing-key")?, key_bytes("next-key")?],
    index_bytes: fixture("index.json").read_bytes()?,
    accepted: null,
    now_epoch_seconds: reference_now(),
  }
  let rotated = repo_snapshot.snapshot_verify(gen2)?

  assert rotated.generation == "2"

  expect_snapshot_rejected({...gen2, keys: [key_bytes("signing-key")?]}, "signature is invalid")
  expect_snapshot_rejected({...verify_input([key_bytes("next-key")?], null)?}, "signature is invalid")
}

test test_snapshot_verify_rejects_wrong_signer_and_tampering [fs, error] { |_|
  let base = verify_input([key_bytes("signing-key")?], null)?

  expect_snapshot_rejected({...base, keys: [key_bytes("wrong-key")?]}, "signature is invalid")
  expect_snapshot_rejected(
    {...base, signature: snapshot_bytes("snapshot-gen1-wrongsigned", "metadata.sig")?},
    "signature is invalid",
  )
  expect_snapshot_rejected(
    {...base, metadata: bytes.from_text(snapshot_bytes("snapshot-gen1", "metadata")?.utf8()?.replace("generation 1", with: "generation 9"))},
    "signature is invalid",
  )
  expect_snapshot_rejected(
    {...base, index_bytes: bytes.from_text(fixture("index.json").read_text()?.replace("fixture-payload", with: "tampered-payload"))},
    "does not match signed snapshot metadata",
  )
}

test test_snapshot_verify_rejects_expiry_bounds [fs, error] { |_|
  let base = verify_input([key_bytes("signing-key")?], null)?

  expect_snapshot_rejected({...base, now_epoch_seconds: reference_expires()}, "has expired")
  expect_snapshot_rejected({...base, now_epoch_seconds: reference_expires() - 7776001}, "exceeds the 90-day validity limit")
}

test test_snapshot_verify_rejects_malformed_metadata_and_inputs [fs, error] { |_|
  let base = verify_input([key_bytes("signing-key")?], null)?
  let good_text = snapshot_bytes("snapshot-gen1", "metadata")?.utf8()?
  let good_sig = snapshot_bytes("snapshot-gen1", "metadata.sig")?

  for {mutated, fragment} in [
    {mutated: "laputa-repo-snapshot-v0\ngeneration 1\nexpires-at 2000000000\nindex-sha256 " + reference_digest() + "\n", fragment: "header or field count"},
    {mutated: good_text + "extra\n", fragment: "header or field count"},
    {mutated: good_text.replace("generation 1", with: "generation 01"), fragment: "generation is invalid"},
    {mutated: good_text.replace("generation 1", with: "generation 0"), fragment: "generation is invalid"},
    {mutated: good_text.replace("generation 1", with: "generation 18446744073709551616"), fragment: "generation is invalid"},
    {mutated: good_text.replace("expires-at 2000000000", with: "expires-at soon"), fragment: "expiry is invalid"},
    {mutated: good_text.replace("index-sha256", with: "index-sha255"), fragment: "index digest is invalid"},
    {mutated: good_text.replace("\n", with: "\r\n"), fragment: "LF-terminated"},
    {mutated: good_text.byte_slice(0, good_text.byte_len() - 1), fragment: "LF-terminated"},
  ] {
    match repo_snapshot.snapshot_parse_metadata(bytes.from_text(mutated)) {
      Ok(_) => test.fail(f"malformed snapshot metadata was accepted: {fragment}"),
      Err(problem) => assert fragment in problem.message
    }
  }

  match repo_snapshot.snapshot_parse_metadata(bytes.zero(4097)?) {
    Ok(_) => test.fail("oversize snapshot metadata was accepted"),
    Err(problem) => assert "metadata size is invalid" in problem.message
  }

  expect_snapshot_rejected({...base, metadata: bytes.from_text(good_text.replace("generation 1", with: "generation 9")), signature: good_sig}, "signature is invalid")
  expect_snapshot_rejected({...base, signature: good_sig.slice(0, 63)}, "64 raw Ed25519 bytes")
  expect_snapshot_rejected({...base, signature: bytes.from_text("")}, "64 raw Ed25519 bytes")
  expect_snapshot_rejected({...base, keys: []}, "no repository snapshot verification key")
  expect_snapshot_rejected({...base, keys: [key_bytes("signing-key")?.slice(0, 31)]}, "exactly 32 raw Ed25519 bytes")
  expect_snapshot_rejected({...base, index_bytes: bytes.from_text("[]\n")}, "does not match signed snapshot metadata")
}

test test_snapshot_verify_enforces_accepted_floor_and_clock [fs, error] { |_|
  let base = verify_input([key_bytes("signing-key")?], null)?
  let verified = repo_snapshot.snapshot_verify(base)?
  let accepted = {generation: verified.generation, index_sha256: verified.index_sha256, lower_bound: reference_now() - 10}

  let replayed = repo_snapshot.snapshot_verify({...base, accepted})?
  assert replayed.generation == "1"

  let gen2 = {
    metadata: snapshot_bytes("snapshot-gen2", "metadata")?,
    signature: snapshot_bytes("snapshot-gen2", "metadata.sig")?,
    keys: [key_bytes("signing-key")?, key_bytes("next-key")?],
    index_bytes: fixture("index.json").read_bytes()?,
    accepted,
    now_epoch_seconds: reference_now(),
  }
  assert repo_snapshot.snapshot_verify(gen2)?.generation == "2"

  let rolled_back = {
    metadata: snapshot_bytes("snapshot-gen1", "metadata")?,
    signature: snapshot_bytes("snapshot-gen1", "metadata.sig")?,
    keys: [key_bytes("signing-key")?],
    index_bytes: fixture("index.json").read_bytes()?,
    accepted: {generation: "2", index_sha256: verified.index_sha256, lower_bound: reference_now() - 10},
    now_epoch_seconds: reference_now(),
  }
  expect_snapshot_rejected(rolled_back, "rolls back the accepted snapshot")

  let frozen = {
    metadata: snapshot_bytes("snapshot-gen2b", "metadata")?,
    signature: snapshot_bytes("snapshot-gen2b", "metadata.sig")?,
    keys: [key_bytes("signing-key")?, key_bytes("next-key")?],
    index_bytes: fixture("index2.json").read_bytes()?,
    accepted: {generation: "2", index_sha256: verified.index_sha256, lower_bound: reference_now() - 10},
    now_epoch_seconds: reference_now(),
  }
  expect_snapshot_rejected(frozen, "does not advance the accepted snapshot")

  let clock_rollback = {...base, accepted: {...accepted, lower_bound: reference_now() + 1}}
  expect_snapshot_rejected(clock_rollback, "behind the last observed repository snapshot time")
}

test test_snapshot_key_file_and_accepted_state_round_trip [fs, error] { |ctx|
  let key_file = test.temp_path(ctx, name: "repo-keys")
  key_file.write(bytes.concat([key_bytes("signing-key")?, key_bytes("next-key")?]))
  let keys = repo_snapshot.snapshot_load_keys(key_file)?

  assert keys.len() == 2

  let odd = test.temp_path(ctx, name: "repo-keys-odd")
  odd.write(key_bytes("signing-key")?.slice(0, 31))

  match repo_snapshot.snapshot_load_keys(odd) {
    Ok(_) => test.fail("odd-length key file was accepted"),
    Err(problem) => assert "concatenated raw 32-byte" in problem.message
  }

  match repo_snapshot.snapshot_load_keys(test.temp_path(ctx, name: "repo-keys-missing")) {
    Ok(_) => test.fail("missing key file was accepted"),
    Err(problem) => assert "no repository snapshot verification key is provisioned" in problem.message
  }

  let state = repo_snapshot.snapshot_state_paths(test.temp_dir(ctx, name: "repo-state")?, "https://example.invalid/repo")

  if repo_snapshot.snapshot_read_accepted(state)? != null {
    test.fail("fresh accepted state was not empty")
  }

  let verified = repo_snapshot.snapshot_verify(verify_input(keys, null)?)?
  repo_snapshot.snapshot_persist_accepted(state, verified, reference_now())?
  let stored = repo_snapshot.snapshot_read_accepted(state)?

  if stored == null {
    test.fail("persisted accepted state was not readable")
  } else {
    assert stored.generation == "1"
    assert stored.lower_bound == reference_now()
  }

  repo_snapshot.snapshot_persist_accepted(state, verified, reference_now() - 100)?
  let restored = repo_snapshot.snapshot_read_accepted(state)?

  if restored == null {
    test.fail("accepted state vanished after re-persist")
  } else {
    assert restored.lower_bound == reference_now()
  }

  state.accepted.write("corrupt\n")

  match repo_snapshot.snapshot_read_accepted(state) {
    Ok(_) => test.fail("corrupt accepted state was accepted"),
    Err(problem) => assert "accepted repository snapshot state is corrupt" in problem.message
  }
}

proc stage_snapshot_remote(ctx: TestContext, index_source: Path) -> Result[Path] {
  let remote_root = test.temp_dir(ctx, name: "snapshot-remote")?
  index_source.copy(to: fp"{remote_root}/index.json")
  remote_root
}

proc stage_snapshot_dir(ctx: TestContext, name: Str, which: Str) -> Result[Path] {
  let dir = fp"{test.temp_dir(ctx, name: name)?}/snapshot"
  dir.mkdir(parents: true)
  fixture(f"{which}/metadata").copy(to: fp"{dir}/snapshot.json")
  fixture(f"{which}/metadata.sig").copy(to: fp"{dir}/snapshot.sig")
  dir
}

test test_publish_snapshot_binds_index_advances_and_freezes [fs, net, env, time, error] { |ctx|
  let remote_root = stage_snapshot_remote(ctx, fixture("index.json"))?
  let remote_url = f"file://{remote_root}"
  let both_keys = [key_bytes("signing-key")?, key_bytes("next-key")?]
  let work = test.temp_dir(ctx, name: "snapshot-publish-work")?

  match repo.publish_snapshot(remote_url, "", work, stage_snapshot_dir(ctx, "snapshot-gen1-dir", "snapshot-gen1")?, both_keys) {
    Ok(_) => {},
    Err(problem) => test.fail(f"valid snapshot publication failed: {problem.message}"),
  }

  assert fp"{remote_root}/snapshot.json".read_bytes()? == snapshot_bytes("snapshot-gen1", "metadata")?
  assert fp"{remote_root}/snapshot.sig".read_bytes()? == snapshot_bytes("snapshot-gen1", "metadata.sig")?

  repo.publish_snapshot(remote_url, "", work, stage_snapshot_dir(ctx, "snapshot-gen1-replay-dir", "snapshot-gen1")?, both_keys)

  match repo.publish_snapshot(remote_url, "", work, stage_snapshot_dir(ctx, "snapshot-gen2-dir", "snapshot-gen2")?, [key_bytes("signing-key")?]) {
    Ok(_) => test.fail("snapshot signed by a superseded key advanced the repository"),
    Err(problem) => assert "signature is invalid" in problem.message
  }

  repo.publish_snapshot(remote_url, "", work, stage_snapshot_dir(ctx, "snapshot-gen2-again-dir", "snapshot-gen2")?, both_keys)?
  assert fp"{remote_root}/snapshot.json".read_bytes()? == snapshot_bytes("snapshot-gen2", "metadata")?

  match repo.publish_snapshot(remote_url, "", work, stage_snapshot_dir(ctx, "snapshot-gen1-again-dir", "snapshot-gen1")?, both_keys) {
    Ok(_) => test.fail("a stale snapshot generation advanced the repository"),
    Err(problem) => assert "does not advance the published generation" in problem.message
  }
}

test test_publish_snapshot_rejects_unbound_and_incomplete_inputs [fs, net, env, time, error] { |ctx|
  let remote_root = stage_snapshot_remote(ctx, fixture("index.json"))?
  let remote_url = f"file://{remote_root}"
  let both_keys = [key_bytes("signing-key")?, key_bytes("next-key")?]
  let work = test.temp_dir(ctx, name: "snapshot-publish-reject-work")?

  fp"{remote_root}/index.json".write("{\"tampered\": true}\n")

  match repo.publish_snapshot(remote_url, "", work, stage_snapshot_dir(ctx, "snapshot-unbound-dir", "snapshot-gen1")?, both_keys) {
    Ok(_) => test.fail("a snapshot over a different index was published"),
    Err(problem) => assert "does not match the published index" in problem.message
  }

  let bare = test.temp_dir(ctx, name: "snapshot-bare")?

  match repo.publish_snapshot(remote_url, "", work, bare, both_keys) {
    Ok(_) => test.fail("a snapshot directory without files was published"),
    Err(problem) => assert "missing snapshot.json" in problem.message
  }

  match repo.publish_snapshot("", "", work, stage_snapshot_dir(ctx, "snapshot-empty-repo-dir", "snapshot-gen1")?, both_keys) {
    Ok(_) => test.fail("a snapshot without a repository was published"),
    Err(problem) => assert "needs a remote repository" in problem.message
  }

  match repo.publish_snapshot(remote_url, "", work, stage_snapshot_dir(ctx, "snapshot-nokey-dir", "snapshot-gen1")?, []) {
    Ok(_) => test.fail("a snapshot without keys was published"),
    Err(problem) => assert "no repository snapshot verification key" in problem.message
  }

  assert ! fp"{remote_root}/snapshot.json".exists()?
}

pure snapshot_response(url: Str, body: Bytes) -> NetResponse {
  {
    status: 200,
    reason: "OK",
    bytes: body.len(),
    headers: [],
    url,
    effective_url: url,
    redirect_count: 0,
    body,
  }
}

test test_verified_fetch_accepts_signed_index_and_caches_exact_bytes [fs, net, env, time, error] { |ctx|
  let repo = "https://example.invalid/repo"
  let index_text = fixture("index.json").read_text()?
  test.mock(ctx, "net.request", {url: f"{repo}/snapshot.json"}, Ok(snapshot_response(f"{repo}/snapshot.json", snapshot_bytes("snapshot-gen1", "metadata")?)), 2)
  test.mock(ctx, "net.request", {url: f"{repo}/snapshot.sig"}, Ok(snapshot_response(f"{repo}/snapshot.sig", snapshot_bytes("snapshot-gen1", "metadata.sig")?)), 2)
  test.mock(ctx, "net.request", {url: f"{repo}/index.json"}, Ok(snapshot_response(f"{repo}/index.json", bytes.from_text(index_text))), 2)

  let out = test.temp_dir(ctx, name: "verified-fetch-out")?
  let state = test.temp_dir(ctx, name: "verified-fetch-state")?
  let index = remote.load_verified_remote_index(repo, out, [key_bytes("signing-key")?], reference_now(), state.display())?

  assert index.len() == 1
  assert index[0].name == "fixture"
  assert pm_util.remote_index_cache_path(out).read_bytes()? == fixture("index.json").read_bytes()?
  let accepted_state = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(state, repo))?

  if accepted_state == null {
    test.fail("verified fetch did not persist accepted state")
  } else {
    assert accepted_state.generation == "1"
  }

  let replayed = remote.load_verified_remote_index(repo, out, [key_bytes("signing-key")?], reference_now(), state.display())?
  assert replayed.len() == 1
}

test test_verified_fetch_rejects_missing_snapshot [fs, net, env, time, error] { |ctx|
  let repo = "https://example.invalid/missing"
  let missing: NetResponse = {
    status: 404,
    reason: "Not Found",
    bytes: 0,
    headers: [],
    url: f"{repo}/snapshot.json",
    effective_url: f"{repo}/snapshot.json",
    redirect_count: 0,
    body: b"",
  }
  test.mock(ctx, "net.request", {url: f"{repo}/snapshot.json"}, Ok(missing))

  match remote.load_verified_remote_index(repo, test.temp_dir(ctx, name: "verified-fetch-missing-out")?, [key_bytes("signing-key")?], reference_now(), "") {
    Ok(_) => test.fail("a missing snapshot was accepted"),
    Err(problem) => assert "snapshot.json" in problem.message
  }
}

test test_verified_fetch_rejects_tampered_index [fs, net, env, time, error] { |ctx|
  let repo = "https://example.invalid/tampered"
  let index_text = fixture("index.json").read_text()?
  let tampered = bytes.from_text(index_text.replace("fixture-payload", with: "tampered-payload"))
  test.mock(ctx, "net.request", {url: f"{repo}/snapshot.json"}, Ok(snapshot_response(f"{repo}/snapshot.json", snapshot_bytes("snapshot-gen1", "metadata")?)))
  test.mock(ctx, "net.request", {url: f"{repo}/snapshot.sig"}, Ok(snapshot_response(f"{repo}/snapshot.sig", snapshot_bytes("snapshot-gen1", "metadata.sig")?)))
  test.mock(ctx, "net.request", {url: f"{repo}/index.json"}, Ok(snapshot_response(f"{repo}/index.json", tampered)))

  let out = test.temp_dir(ctx, name: "verified-fetch-tampered-out")?

  match remote.load_verified_remote_index(repo, out, [key_bytes("signing-key")?], reference_now(), "") {
    Ok(_) => test.fail("a tampered index was accepted"),
    Err(problem) => assert "does not match signed snapshot metadata" in problem.message
  }

  assert ! pm_util.remote_index_cache_path(out).exists()?
}

test test_verified_fetch_rejects_wrong_signer [fs, net, env, time, error] { |ctx|
  let repo = "https://example.invalid/wrongsigned"
  let index_text = fixture("index.json").read_text()?
  test.mock(ctx, "net.request", {url: f"{repo}/snapshot.json"}, Ok(snapshot_response(f"{repo}/snapshot.json", snapshot_bytes("snapshot-gen1", "metadata")?)))
  test.mock(ctx, "net.request", {url: f"{repo}/snapshot.sig"}, Ok(snapshot_response(f"{repo}/snapshot.sig", snapshot_bytes("snapshot-gen1-wrongsigned", "metadata.sig")?)))
  test.mock(ctx, "net.request", {url: f"{repo}/index.json"}, Ok(snapshot_response(f"{repo}/index.json", bytes.from_text(index_text))))

  match remote.load_verified_remote_index(repo, test.temp_dir(ctx, name: "verified-fetch-wrong-out")?, [key_bytes("signing-key")?], reference_now(), "") {
    Ok(_) => test.fail("a wrongly signed snapshot was accepted"),
    Err(problem) => assert "signature is invalid" in problem.message
  }
}

test test_production_plan_without_provisioned_keys_fails_closed [fs, process, env, error] { |ctx|
  let repository = test.temp_dir(ctx, name: "snapshot-plan-repo")?
  let _ = fs.copy_tree(fp"tests/pm/fixtures/graph-catalog/packages", fp"{repository}/packages", parents: true, overwrite: true)?
  fp"{repository}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{repository}/pm/proof.xsh", overwrite: true)
  let xsh = runner()?
  let modules = path.absolute(p".")?
  let output = test.temp_path(ctx, name: "snapshot-plan.json")
  let err = test.temp_path(ctx, name: "snapshot-plan.err")
  let status = run.status XSH_HOST=$xsh XSH_MODULE_PATH=$modules XSH_PM_REPO="https://example.invalid/repo" $xsh pm.xsh -- repo plan \
    --repo $repository --root app --output $output 2> $err

  assert status.ok == false
  assert "needs XSH_PM_REPO_KEY_FILE" in err.read_text()?
}

proc stage_signed_file_repository(ctx: TestContext, name: Str, which: Str) -> Result[Path] {
  let root = test.temp_dir(ctx, name:)?
  fixture("index.json").copy(to: fp"{root}/index.json")
  fixture(f"{which}/metadata").copy(to: fp"{root}/snapshot.json")
  fixture(f"{which}/metadata.sig").copy(to: fp"{root}/snapshot.sig")
  root
}

test test_verified_fetch_accepts_signed_file_repository_and_rejects_tampering [fs, net, env, time, error] { |ctx|
  let root = stage_signed_file_repository(ctx, "verified-file-repo", "snapshot-gen1")?
  let repo = f"file://{root}"
  let keys = [key_bytes("signing-key")?]
  let out = test.temp_dir(ctx, name: "verified-file-out")?
  let state = test.temp_dir(ctx, name: "verified-file-state")?

  let index = remote.load_verified_remote_index(repo, out, keys, reference_now(), state.display())?
  assert index.len() == 1
  assert pm_util.remote_index_cache_path(out).read_bytes()? == fixture("index.json").read_bytes()?

  let accepted = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(state, repo))?
  if accepted == null {
    test.fail("file repository verification did not persist accepted state")
  } else {
    assert accepted.generation == "1"
  }

  fp"{root}/index.json".write(fixture("index.json").read_text()?.replace("fixture-payload", with: "tampered-payload"))
  match remote.load_verified_remote_index(repo, test.temp_dir(ctx, name: "verified-file-tampered-out")?, keys, reference_now(), state.display()) {
    Ok(_) => test.fail("a tampered file repository index was accepted"),
    Err(problem) => assert "does not match signed snapshot metadata" in problem.message
  }

  fp"{root}/snapshot.json".remove()
  match remote.load_verified_remote_index(repo, test.temp_dir(ctx, name: "verified-file-missing-out")?, keys, reference_now(), state.display()) {
    Ok(_) => test.fail("a file repository without a snapshot was accepted"),
    Err(problem) => assert "snapshot.json" in problem.message
  }
}

test test_verified_fetch_rejects_rollback_of_accepted_file_repository [fs, net, env, time, error] { |ctx|
  let root = stage_signed_file_repository(ctx, "verified-file-rollback", "snapshot-gen2")?
  let url = f"file://{root}"
  let keys = [key_bytes("signing-key")?, key_bytes("next-key")?]
  let state = test.temp_dir(ctx, name: "verified-file-rollback-state")?
  let _ = remote.load_verified_remote_index(url, test.temp_dir(ctx, name: "verified-file-rollback-out")?, keys, reference_now(), state.display())?

  fixture("snapshot-gen1/metadata").copy(to: fp"{root}/snapshot.json", overwrite: true)
  fixture("snapshot-gen1/metadata.sig").copy(to: fp"{root}/snapshot.sig", overwrite: true)

  match remote.load_verified_remote_index(url, test.temp_dir(ctx, name: "verified-file-rollback-replay-out")?, keys, reference_now(), state.display()) {
    Ok(_) => test.fail("a rolled-back file repository snapshot was accepted"),
    Err(problem) => assert "accepted snapshot" in problem.message
  }

  let accepted = repo_snapshot.snapshot_read_accepted(repo_snapshot.snapshot_state_paths(state, url))?
  if accepted == null {
    test.fail("accepted state vanished after a rejected rollback")
  } else {
    assert accepted.generation == "2"
  }
}

test test_persist_accepted_refuses_generation_rollback_and_never_lowers_bound [fs, error] { |ctx|
  let state = repo_snapshot.snapshot_state_paths(test.temp_dir(ctx, name: "persist-rollback-state")?, "https://example.invalid/repo")
  let keys = [key_bytes("signing-key")?, key_bytes("next-key")?]
  let gen2 = repo_snapshot.snapshot_verify({...verify_input(keys, null)?, metadata: snapshot_bytes("snapshot-gen2", "metadata")?, signature: snapshot_bytes("snapshot-gen2", "metadata.sig")?})?
  let gen1 = repo_snapshot.snapshot_verify(verify_input(keys, null)?)?

  repo_snapshot.snapshot_persist_accepted(state, gen2, reference_now())?
  let before = state.accepted.read_bytes()?

  match repo_snapshot.snapshot_persist_accepted(state, gen1, reference_now()) {
    Ok(_) => test.fail("direct persistence regressed the accepted generation"),
    Err(problem) => assert "rolls back" in problem.message
  }

  assert state.accepted.read_bytes()? == before
}

test test_plan_over_local_repository_with_keys_requires_a_valid_snapshot [fs, process, env, error] { |ctx|
  let repository = test.temp_dir(ctx, name: "snapshot-local-plan-repo")?
  let _ = fs.copy_tree(fp"tests/pm/fixtures/graph-catalog/packages", fp"{repository}/packages", parents: true, overwrite: true)?
  fp"{repository}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{repository}/pm/proof.xsh", overwrite: true)
  let mirror = stage_signed_file_repository(ctx, "snapshot-local-plan-mirror", "snapshot-gen1")?
  let key_file = test.temp_path(ctx, name: "snapshot-local-plan-keys")
  key_file.write(key_bytes("signing-key")?)
  let state = test.temp_dir(ctx, name: "snapshot-local-plan-state")?
  let xsh = runner()?
  let modules = path.absolute(p".")?
  let mirror_url = f"file://{mirror}"

  let unsigned_dir = test.temp_dir(ctx, name: "snapshot-local-plan-unsigned")?
  fixture("index.json").copy(to: fp"{unsigned_dir}/index.json")
  let unsigned_output = test.temp_path(ctx, name: "snapshot-local-plan-unsigned.json")
  let unsigned_err = test.temp_path(ctx, name: "snapshot-local-plan-unsigned.err")
  let unsigned_url = f"file://{unsigned_dir}"
  let unsigned = run.status XSH_HOST=$xsh XSH_MODULE_PATH=$modules XSH_PM_REPO=$unsigned_url XSH_PM_REPO_KEY_FILE=$key_file XSH_PM_REPO_STATE_DIR=$state $xsh pm.xsh -- repo plan \
    --repo $repository --root app --output $unsigned_output 2> $unsigned_err

  assert unsigned.ok == false
  assert "snapshot.json" in unsigned_err.read_text()?

  let verified_output = test.temp_path(ctx, name: "snapshot-local-plan-verified.json")
  let verified_err = test.temp_path(ctx, name: "snapshot-local-plan-verified.err")
  let verified = run.status XSH_HOST=$xsh XSH_MODULE_PATH=$modules XSH_PM_REPO=$mirror_url XSH_PM_REPO_KEY_FILE=$key_file XSH_PM_REPO_STATE_DIR=$state $xsh pm.xsh -- repo plan \
    --repo $repository --root app --output $verified_output 2> $verified_err

  assert verified.ok == false
  assert "repository snapshot expiry" in verified_err.read_text()?

  let keyless_output = test.temp_path(ctx, name: "snapshot-local-plan-keyless.json")
  let keyless_err = test.temp_path(ctx, name: "snapshot-local-plan-keyless.err")
  let keyless = run.status XSH_HOST=$xsh XSH_MODULE_PATH=$modules XSH_PM_REPO=$mirror_url $xsh pm.xsh -- repo plan \
    --repo $repository --root app --output $keyless_output 2> $keyless_err

  assert keyless.ok, keyless_err.read_text()?
}
