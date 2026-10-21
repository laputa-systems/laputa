##! XSH module `proof` package and build operations.
error ProofError = Failed(kind: Str, message: Str)

proc ensure(condition: Bool, kind: Str, message: Str) [error] {
  guard condition else {
    return Err(ProofError.Failed(kind:, message:))
  }
}

proc verify_package_metadata(rootfs: Path) {
  let metadata_path = fp"{rootfs}/var/lib/xsh-pm/packages/ca-certificates/metadata.json"
  ensure(metadata_path.exists()?, "ca-certificates-metadata", "missing package metadata")
  let metadata = json.read(metadata_path)?.require(Record)?
  let deps = metadata.get("deps")?.require(List[Str])?
  ensure(deps.is_empty(), "ca-certificates-deps", f"expected no runtime deps, got {deps.join(" ")}")
}

proc main(rootfs = /rootfs) [fs, error] {
  let bundle = fp"{rootfs}/etc/ssl/certs/ca-certificates.crt"
  ensure(bundle.exists()?, "ca-certificates-bundle", "missing /etc/ssl/certs/ca-certificates.crt")
  let body = bundle.read_text()?
  let cert_count = body.split("-----BEGIN CERTIFICATE-----").len() - 1
  ensure(cert_count == 118, "ca-certificates-bundle", f"expected 118 certificates, found {cert_count}")
  ensure(
    "MIICTjCCAdOgAgIKPPYHqWhwDtqLhDAKB" not in body,
    "ca-certificates-bundle",
    "bundle retains the removed emSign G3 root",
  )

  verify_package_metadata(rootfs)
  print f"ca-certificates ok: {cert_count} certificates; emSign G3 root absent"
}
