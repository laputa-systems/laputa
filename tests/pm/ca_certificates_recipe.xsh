##! Certificate package proof checks the pinned trust roots and dependency boundary.

proc runner() -> Result[Path] {
  let configured = e"XSH_HOST" ?? ""
  return fp"{configured}" when configured != ""
  process.which("xsh")?
}

test ca_certificate_proof_checks_pinned_roots_and_rejects_invalid_metadata [fs, process, env, error] { |ctx|
  let root = test.temp_dir(ctx, name: "certificate proof")?
  let bundle = fp"{root}/etc/ssl/certs/ca-certificates.crt"
  let helper = fp"{root}/usr/bin/update-certdata"
  let metadata = fp"{root}/var/lib/xsh-pm/packages/ca-certificates/metadata.json"
  let stderr = fp"{root}/proof.stderr"
  for file in [bundle, metadata] { file.parent.mkdir() }
  var valid_bundle = ""
  for _ in range(118) { valid_bundle += "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n" }
  bundle.write(valid_bundle)
  let xsh = runner()?
  let command = process.command_argv(xsh, [xsh, p"packages/ca-certificates/proof.xsh", "--", root], stderr:)
  json.write(metadata, {deps: [], extension: {source: "fixture"}})
  assert process.run(command)?.ok
  assert ! helper.exists()?
  bundle.write("-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----\n")
  assert ! process.run(command)?.ok
  assert "expected 118 certificates" in stderr.read_text()?
  bundle.write(valid_bundle.replace("fixture", with: "MIICTjCCAdOgAgIKPPYHqWhwDtqLhDAKB"))
  assert ! process.run(command)?.ok
  assert "bundle retains the removed emSign G3 root" in stderr.read_text()?
  bundle.write(valid_bundle)
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
