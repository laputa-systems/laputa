##! Certificate package proof checks the pinned trust roots and dependency boundary.

proc runner() -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  return fp"{configured}" when configured != ""
  process.which("xsh")?
}

test ca_certificate_proof_checks_pinned_roots_and_rejects_invalid_metadata [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "certificate proof")?
  let bundle = fp"{root}/etc/ssl/certs/ca-certificates.crt"
  let policy = fp"{root}/etc/laputa/trust-policy"
  let metadata = fp"{root}/var/lib/xsh-pm/packages/ca-certificates/metadata.json"
  let stderr = fp"{root}/proof.stderr"
  for file in [bundle, policy, metadata] { file.parent.mkdir() }
  let valid_bundle = p"packages/ca-certificates/files/cacert.pem".read_text()?
  bundle.write(valid_bundle)
  policy.write(p"packages/ca-certificates/files/trust-policy".read_text()?)
  let xsh = runner()?
  let command = process.command_argv(xsh, [xsh, p"packages/ca-certificates/proof.xsh", "--", root], stderr:)
  json.write(metadata, {deps: [], extension: {source: "fixture"}})
  assert process.run(command)?.ok
  bundle.write("-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n")
  assert ! process.run(command)?.ok
  assert "expected 118 certificates" in stderr.read_text()?
  bundle.write(valid_bundle + "MIICTjCCAdOgAgIKPPYHqWhwDtqLhDAKB")
  assert ! process.run(command)?.ok
  assert "bundle retains the removed emSign G3 root" in stderr.read_text()?
  bundle.write(valid_bundle)
  var malformed_bundle = ""
  for _ in range(118) { malformed_bundle += "-----BEGIN CERTIFICATE-----\nAQ==\n-----END CERTIFICATE-----\n" }
  bundle.write(malformed_bundle)
  assert ! process.run(command)?.ok
  assert "certificate" in stderr.read_text()?.lower()
  bundle.write(valid_bundle)
  policy.write("laputa-trust-policy-v1\ngeneration 1\nblocked-spki-sha256 NOT-A-DIGEST\n")
  assert ! process.run(command)?.ok
  assert "policy contains an unknown or malformed field" in stderr.read_text()?
  policy.write(
    p"packages/ca-certificates/files/trust-policy".read_text()?.replace(
      "blocked-spki-sha256 ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105\n",
      with: "",
    ),
  )
  assert ! process.run(command)?.ok
  assert "trust policy is missing blocked SPKI" in stderr.read_text()?
  policy.write(p"packages/ca-certificates/files/trust-policy".read_text()?)
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
