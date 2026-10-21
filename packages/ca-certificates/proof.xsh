##! Checks the composed certificate package roots and distrust policy.
use trust.policy as trust_policy

let REQUIRED_BLOCKED_SPKIS = [
  "43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b",
  "49dd353dc2b919a3770645117d0e60c16115e7d1bc259eefe734b00ea434fe5f",
  "5c0660a2b164910d8ff589c18e14552e9e0ec237dcefe2cb736d41a4811f81a0",
  "63ecefee431d49523bc1136c4e72d0206a477086caf606cd5cf025686c109cf8",
  "e0254c7fcdc265e2f0f8a428dabb75ab4ae039b4872d62f5ee57f0877d5a8a41",
  "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105",
]

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

proc verify_distrust_policy(rootfs: Path) [fs, error] {
  let policy_path = fp"{rootfs}/etc/laputa/trust-policy"
  ensure(policy_path.exists()?, "ca-certificates-policy", "missing /etc/laputa/trust-policy")
  let policy = trust_policy.parse(policy_path.read_bytes()?)?
  for spki in REQUIRED_BLOCKED_SPKIS {
    ensure(spki in policy.blocked_spki_sha256, "ca-certificates-policy", f"trust policy is missing blocked SPKI {spki}")
  }
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
  net.validate_root_bundle(bundle.read_bytes()?)?

  verify_distrust_policy(rootfs)
  verify_package_metadata(rootfs)
  print f"ca-certificates ok: {cert_count} certificates; emSign G3 root absent; 6 SPKIs blocked"
}
