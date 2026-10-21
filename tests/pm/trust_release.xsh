##! Signed trust-release verification and immutable-generation publication tests.
use pm.catalog
use pm.generation
use pm.plan
use pm.policy
use pm.store
use pm.types
use trust.release as trust_release

pure fixture(name: Str) -> Path {
  fp"tests/fixtures/trust-release/{name}"
}

proc signed_release_input(name: Str) [fs, error] -> Result[trust_release.SignedReleaseInput, Error] {
  let metadata = fixture(f"{name}.metadata").read_bytes()?
  let signature = fixture(f"{name}.signature.base64").read_text()?.trim().base64_decode()?
  let provisioned_public_key = fixture("test-public-key.base64").read_text()?.trim().base64_decode()?
  let root_bundle = if name == "malformed-root" {
    fixture("malformed-root.pem").read_bytes()?
  } else {
    p"packages/ca-certificates/files/cacert.pem".read_bytes()?
  }
  let next_policy = fixture("policy-v2").read_bytes()?
  let installed_policy_snapshot = p"packages/ca-certificates/files/trust-policy".read_bytes()?
  {
    metadata,
    signature,
    provisioned_public_key,
    root_bundle,
    next_policy,
    installed_policy_snapshot,
    now_epoch_seconds: 1792540800,
  }
}

proc trust_build_plan(ctx: TestContext) -> Result[types.BuildPlan] {
  let repo_root = test.temp_dir(ctx, name: "trust-release-repository")?
  let _ = fs.copy_tree(p"packages/ca-certificates", fp"{repo_root}/packages/ca-certificates", parents: true, overwrite: true)?
  fp"{repo_root}/pm".mkdir()
  p"pm/proof.xsh".copy(to: fp"{repo_root}/pm/proof.xsh", overwrite: true)
  plan.resolve(
    catalog.load(repo_root)?,
    {target: types.Aarch64LinuxMusl, index_sha256: "trust-release-index", packages: []},
    policy.aarch64_docker(),
    ["ca-certificates"],
    false,
  )?
}

proc stage_trust_artifact(ctx: TestContext, value: types.BuildPlan, store_root: Path) {
  let node = value.nodes[0]
  let stage = test.temp_dir(ctx, name: "trust-release-package")?
  let contents = fp"{stage}/contents"
  let bundle = p"packages/ca-certificates/files/cacert.pem"
  let current_policy = p"packages/ca-certificates/files/trust-policy"
  let bundle_path = fp"{contents}/etc/ssl/certs/ca-certificates.crt"
  let policy_path = fp"{contents}/etc/laputa/trust-policy"
  let cert_link = fp"{contents}/etc/ssl/cert.pem"
  let payload = fp"{stage}/payload.tar.gz"
  let metadata = fp"{stage}/metadata.json"
  let proof = fp"{stage}/proof.json"
  bundle_path.parent.mkdir(parents: true)
  policy_path.parent.mkdir(parents: true)
  bundle_path.write(bundle.read_bytes()?)
  policy_path.write(current_policy.read_bytes()?)
  cert_link.symlink(to: p"certs/ca-certificates.crt")
  archive.tar_create(payload, contents, [p"."], compression: "gz")
  json.write(
    metadata,
    {
      arch: types.pm_target_arch(value.target),
      name: node.name,
      ver: node.ver,
      rel: node.rel,
      package_kind: "payload",
      files: [
        {
          path: "etc/laputa/trust-policy",
          kind: "file",
          mode: 0o644,
          sha256: hash.sha256(current_policy)?.hex(),
          target: "",
        },
        {
          path: "etc/ssl/cert.pem",
          kind: "symlink",
          mode: 0o777,
          sha256: "",
          target: "certs/ca-certificates.crt",
        },
        {
          path: "etc/ssl/certs/ca-certificates.crt",
          kind: "file",
          mode: 0o644,
          sha256: hash.sha256(bundle)?.hex(),
          target: "",
        },
      ],
    },
  )
  proof.write("fixture proof\n")
  let _ = store.commit(
    value.target,
    store_root,
    node,
    {
      payload,
      payload_sha256: hash.sha256(payload)?.hex(),
      metadata,
      proof,
      executor_sha256: bytes.from_text("trust release fixture executor").sha256().hex(),
    },
  )?
}

proc expect_rejected_without_mutation(
  ctx: TestContext,
  input: trust_release.SignedReleaseInput,
  value: types.BuildPlan,
  old_generation: Path,
  store_root: Path,
  name: Str,
  expected: Str,
) {
  let overlay_parent = test.temp_dir(ctx, name: f"trust-release-overlay-{name}")?
  let overlay_root = fp"{overlay_parent}/staged"
  match trust_release.compose_signed_release(
    input,
    {
      build_plan: value,
      runtime_roots: ["ca-certificates"],
      store_root,
      output_root: old_generation,
      overlay_root,
    },
  ) {
    Ok(_) => test.fail(f"{name}: invalid signed release was accepted")
    Err(problem) => assert expected in problem.message
  }
  assert fp"{old_generation}/generation-marker".read_text()? == "prior generation\n"
  assert ! overlay_root.exists()?
}

test trust_release_composes_authenticated_bytes_as_one_generation [fs, env, error] { |ctx|
  let input = signed_release_input("valid")?
  let value = trust_build_plan(ctx)?
  let store_root = test.temp_dir(ctx, name: "trust-release-store")?
  stage_trust_artifact(ctx, value, store_root)
  let old_generation = test.temp_dir(ctx, name: "trust-release-old-generation")?
  fp"{old_generation}/generation-marker".write("prior generation\n")
  let output_root = test.temp_path(ctx, name: "trust-release-next-generation")
  let overlay_parent = test.temp_dir(ctx, name: "trust-release-overlay-valid")?
  let overlay_root = fp"{overlay_parent}/staged"

  let receipt = trust_release.compose_signed_release(
    input,
    {
      build_plan: value,
      runtime_roots: ["ca-certificates"],
      store_root,
      output_root,
      overlay_root,
    },
  )?

  assert receipt.profile.name == "trust-release"
  assert receipt.profile.replacements == ["etc/laputa/trust-policy", "etc/ssl/certs/ca-certificates.crt"]
  assert fp"{output_root}/etc/laputa/trust-policy".read_bytes()? == input.next_policy
  assert fp"{output_root}/etc/ssl/certs/ca-certificates.crt".read_bytes()? == input.root_bundle
  assert fp"{old_generation}/generation-marker".read_text()? == "prior generation\n"
  assert ! overlay_root.exists()?
  generation.verify_generation(output_root, receipt)

  let second_overlay = fp"{overlay_parent}/second-staging"
  match trust_release.compose_signed_release(
    input,
    {
      build_plan: value,
      runtime_roots: ["ca-certificates"],
      store_root,
      output_root,
      overlay_root: second_overlay,
    },
  ) {
    Ok(_) => test.fail("signed release overwrote an immutable generation")
    Err(problem) => assert "already exists" in problem.message
  }
  assert fp"{output_root}/etc/laputa/trust-policy".read_bytes()? == input.next_policy
  assert ! second_overlay.exists()?
}

test trust_release_rejects_bad_metadata_and_keeps_the_old_generation [fs, env, error] { |ctx|
  let value = trust_build_plan(ctx)?
  let store_root = test.temp_dir(ctx, name: "trust-release-reject-store")?
  let old_generation = test.temp_dir(ctx, name: "trust-release-reject-old")?
  fp"{old_generation}/generation-marker".write("prior generation\n")
  let valid = signed_release_input("valid")?
  var oversized_metadata = ""
  for _ in range(4097) { oversized_metadata += "x" }

  expect_rejected_without_mutation(
    ctx,
    {...valid, metadata: bytes.from_text(oversized_metadata)},
    value,
    old_generation,
    store_root,
    "metadata-size",
    "metadata size",
  )
  expect_rejected_without_mutation(
    ctx,
    {...valid, metadata: bytes.from_text(valid.metadata.utf8()?.replace("generation 2", with: "generation 3"))},
    value,
    old_generation,
    store_root,
    "signature",
    "signature is invalid",
  )
  expect_rejected_without_mutation(ctx, signed_release_input("malformed")?, value, old_generation, store_root, "metadata", "field count")
  expect_rejected_without_mutation(ctx, signed_release_input("expired")?, value, old_generation, store_root, "expired", "has expired")
  expect_rejected_without_mutation(ctx, signed_release_input("too-far")?, value, old_generation, store_root, "too-far", "90-day")
  expect_rejected_without_mutation(ctx, signed_release_input("malformed-root")?, value, old_generation, store_root, "root", "invalid certificate DER:")
  expect_rejected_without_mutation(
    ctx,
    {...valid, next_policy: bytes.from_text(valid.next_policy.utf8()?.replace("blocked-spki-sha256", with: "unknown-policy-field"))},
    value,
    old_generation,
    store_root,
    "malformed-policy",
    "unknown or malformed field",
  )
  expect_rejected_without_mutation(
    ctx,
    {...valid, provisioned_public_key: b""},
    value,
    old_generation,
    store_root,
    "missing-key",
    "provisioned 32-byte",
  )
  expect_rejected_without_mutation(
    ctx,
    {...valid, signature: b""},
    value,
    old_generation,
    store_root,
    "signature-size",
    "64 raw Ed25519",
  )
  expect_rejected_without_mutation(
    ctx,
    {...valid, next_policy: bytes.from_text(fixture("policy-v2").read_text()?.replace("generation 2", with: "generation 3"))},
    value,
    old_generation,
    store_root,
    "policy-generation",
    "does not match signed metadata",
  )
  expect_rejected_without_mutation(
    ctx,
    {...valid, root_bundle: bytes.from_text("changed root bundle")},
    value,
    old_generation,
    store_root,
    "root-digest",
    "root bundle digest",
  )
  expect_rejected_without_mutation(
    ctx,
    {...valid, installed_policy_snapshot: fixture("policy-v2").read_bytes()?},
    value,
    old_generation,
    store_root,
    "rollback",
    "does not advance",
  )
  expect_rejected_without_mutation(
    ctx,
    {...valid, next_policy: bytes.from_text(fixture("policy-v2").read_text()?.replace("ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105", with: "0000000000000000000000000000000000000000000000000000000000000000"))},
    value,
    old_generation,
    store_root,
    "policy-digest",
    "policy digest",
  )
}

test trust_release_rejects_generation_and_overlay_path_overlap [fs, env, error] { |ctx|
  let input = signed_release_input("valid")?
  let value = trust_build_plan(ctx)?
  let base = test.temp_dir(ctx, name: "trust-release-overlap")?
  let output_root = fp"{base}/candidate"
  let store_root = test.temp_dir(ctx, name: "trust-release-overlap-store")?
  match trust_release.compose_signed_release(
    input,
    {
      build_plan: value,
      runtime_roots: ["ca-certificates"],
      store_root,
      output_root,
      overlay_root: fp"{output_root}/staged",
    },
  ) {
    Ok(_) => test.fail("generation accepted an overlay below its output path")
    Err(problem) => assert "must not contain one another" in problem.message
  }
  assert ! output_root.exists()?
}

test trust_release_composition_failure_keeps_the_old_generation [fs, env, error] { |ctx|
  let input = signed_release_input("valid")?
  let value = trust_build_plan(ctx)?
  let store_root = test.temp_dir(ctx, name: "trust-release-missing-store")?
  let old_generation = test.temp_dir(ctx, name: "trust-release-composition-old")?
  fp"{old_generation}/generation-marker".write("prior generation\n")
  let base = test.temp_dir(ctx, name: "trust-release-composition-failure")?
  let output_root = fp"{base}/candidate"
  let overlay_root = fp"{base}/staged"

  match trust_release.compose_signed_release(
    input,
    {
      build_plan: value,
      runtime_roots: ["ca-certificates"],
      store_root,
      output_root,
      overlay_root,
    },
  ) {
    Ok(_) => test.fail("composition unexpectedly succeeded without a Store artifact")
    Err(_) => {}
  }

  assert fp"{old_generation}/generation-marker".read_text()? == "prior generation\n"
  assert ! output_root.exists()?
  assert ! overlay_root.exists()?
}
