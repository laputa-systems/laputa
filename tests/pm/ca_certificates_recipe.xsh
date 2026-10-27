##! Certificate package proof checks the pinned trust seeds, managed
##! symlinks, provisioned key, seeded store, and dependency boundary.
use trust.store as trust_store

proc runner() -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  return fp"{configured}" when configured != ""
  process.which("xsh")?
}

proc stage_layout(root: Path) [fs, error] {
  let seed_bundle = fp"{root}/usr/share/laputa/trust/seed/ca-certificates.crt"
  let seed_policy = fp"{root}/usr/share/laputa/trust/seed/trust-policy"
  let key_path = fp"{root}/etc/laputa/trust-update-key"
  for parent in [seed_bundle.parent, key_path.parent, fp"{root}/etc/ssl/certs", fp"{root}/var/lib/xsh-pm/packages/ca-certificates"] {
    parent.mkdir(parents: true)
  }

  seed_bundle.write(p"packages/ca-certificates/files/cacert.pem".read_bytes()?)
  seed_policy.write(p"packages/ca-certificates/files/trust-policy".read_bytes()?)
  key_path.write(bytes.from_text("0123456789abcdef0123456789abcdef"))
  fp"{root}/etc/ssl/certs/ca-certificates.crt".symlink(to: p"../../../var/lib/laputa/trust/active/ca-certificates.crt")
  fp"{root}/etc/laputa/trust-policy".symlink(to: p"../../var/lib/laputa/trust/active/trust-policy")
  fp"{root}/etc/ssl/cert.pem".symlink(to: p"certs/ca-certificates.crt")
  json.write(
    fp"{root}/var/lib/xsh-pm/packages/ca-certificates/metadata.json",
    {deps: [], extension: {source: "fixture"}},
  )
}

proc prove_ok(ctx: TestContext, name: Str) [fs, process, env, error] {
  let root = test.temp_dir(ctx, name: name)?
  stage_layout(root)?
  let xsh = runner()?
  let command = process.command_argv(xsh, [xsh, p"packages/ca-certificates/proof.xsh", "--", root])
  assert process.run(command)?.ok

  let active_bundle = fp"{root}/var/lib/laputa/trust/active/ca-certificates.crt"
  assert active_bundle.read_bytes()? == p"packages/ca-certificates/files/cacert.pem".read_bytes()?
  let active = trust_store.trust_store_read_active(trust_store.trust_store_paths(root))?
  assert active == "1"
}

proc prove_fails(ctx: TestContext, name: Str, mutate: Path, body: Str, fragment: Str) [fs, process, env, error] {
  let root = test.temp_dir(ctx, name: name)?
  stage_layout(root)?
  let stderr = fp"{root}/proof.stderr"
  let xsh = runner()?
  fp"{root}/{mutate}".write(bytes.from_text(body))
  let command = process.command_argv(xsh, [xsh, p"packages/ca-certificates/proof.xsh", "--", root], stderr: stderr)
  assert ! process.run(command)?.ok
  assert fragment in stderr.read_text()?
}

test ca_certificate_proof_checks_pinned_roots_and_managed_store [fs, process, env, error] { |ctx|
  prove_ok(ctx, "certificate proof")?
}

test ca_certificate_proof_pins_each_seed_blocked_spki [fs, process, env, error] { |ctx|
  let seed = p"packages/ca-certificates/files/trust-policy".read_text()?
  let proof_source = p"packages/ca-certificates/proof.xsh".read_text()?
  var count = 0
  for line in seed.split("\n") {
    let fields = line.split(" ")
    continue unless fields.len() == 2 and fields[0] == "blocked-spki-sha256"

    assert fields[1] in proof_source
    count += 1
  }

  assert count == 6
}

test ca_certificate_proof_rejects_tampered_bundle [fs, process, env, error] { |ctx|
  prove_fails(
    ctx,
    "certificate bad bundle",
    p"usr/share/laputa/trust/seed/ca-certificates.crt",
    "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n",
    "expected 118 certificates",
  )?
}

test ca_certificate_proof_rejects_retained_emsign_root [fs, process, env, error] { |ctx|
  prove_fails(
    ctx,
    "certificate emsign root",
    p"usr/share/laputa/trust/seed/ca-certificates.crt",
    p"packages/ca-certificates/files/cacert.pem".read_text()? + "MIICTjCCAdOgAgIKPPYHqWhwDtqLhDAKB",
    "bundle retains the removed emSign G3 root",
  )?
}

test ca_certificate_proof_rejects_malformed_bundle [fs, process, env, error] { |ctx|
  var malformed_bundle = ""
  for _ in range(118) { malformed_bundle += "-----BEGIN CERTIFICATE-----\nAQ==\n-----END CERTIFICATE-----\n" }
  prove_fails(ctx, "certificate malformed bundle", p"usr/share/laputa/trust/seed/ca-certificates.crt", malformed_bundle, "certificate")?
}

test ca_certificate_proof_rejects_malformed_policy [fs, process, env, error] { |ctx|
  prove_fails(
    ctx,
    "certificate malformed policy",
    p"usr/share/laputa/trust/seed/trust-policy",
    "laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 NOT-A-DIGEST\n",
    "policy contains an unknown or malformed field",
  )?
}

test ca_certificate_proof_rejects_missing_blocked_spki [fs, process, env, error] { |ctx|
  prove_fails(
    ctx,
    "certificate missing spki",
    p"usr/share/laputa/trust/seed/trust-policy",
    p"packages/ca-certificates/files/trust-policy".read_text()?.replace(
      "blocked-spki-sha256 ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105\n",
      with: "",
    ),
    "trust policy is missing blocked SPKI",
  )?
}

test ca_certificate_proof_rejects_bad_key [fs, process, env, error] { |ctx|
  prove_fails(ctx, "certificate bad key", p"etc/laputa/trust-update-key", "short", "exactly 32 raw Ed25519 bytes")?
}

test ca_certificate_proof_rejects_bad_metadata [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "certificate bad metadata")?
  stage_layout(root)?
  let stderr = fp"{root}/proof.stderr"
  let xsh = runner()?
  let metadata = fp"{root}/var/lib/xsh-pm/packages/ca-certificates/metadata.json"
  let command = process.command_argv(xsh, [xsh, p"packages/ca-certificates/proof.xsh", "--", root], stderr: stderr)
  json.write(metadata, {deps: ["unexpected-runtime"]})
  assert ! process.run(command)?.ok
  assert "expected no runtime deps" in stderr.read_text()?
  json.write(metadata, {deps: "invalid"})
  assert ! process.run(command)?.ok
  assert "schema" in stderr.read_text()?
  json.write(metadata, {})
  assert ! process.run(command)?.ok
  assert "missing" in stderr.read_text()?
}
