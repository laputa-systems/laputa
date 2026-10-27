##! Checks the composed certificate package roots, managed symlinks, pinned
##! seeds, provisioned key format, and an actually seeded trust store.
use trust.policy as trust_policy
use trust.store as trust_store

error ProofError = Failed(kind: Str, message: Str)

let REQUIRED_BLOCKED_SPKIS = [
  "43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b",
  "49dd353dc2b919a3770645117d0e60c16115e7d1bc259eefe734b00ea434fe5f",
  "5c0660a2b164910d8ff589c18e14552e9e0ec237dcefe2cb736d41a4811f81a0",
  "63ecefee431d49523bc1136c4e72d0206a477086caf606cd5cf025686c109cf8",
  "e0254c7fcdc265e2f0f8a428dabb75ab4ae039b4872d62f5ee57f0877d5a8a41",
  "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105",
]

proc ensure(condition: Bool, kind: Str, message: Str) [error] {
  guard condition else {
    return Err(ProofError.Failed(kind:, message:))
  }
}

proc verify_package_metadata(rootfs: Path) [fs, error] {
  let metadata_path = fp"{rootfs}/var/lib/xsh-pm/packages/ca-certificates/metadata.json"
  ensure(metadata_path.exists()?, "ca-certificates-metadata", "missing package metadata")
  let metadata = json.read(metadata_path)?.require(Record)?
  let deps = metadata.get("deps")?.require(List[Str])?
  ensure(deps.is_empty(), "ca-certificates-deps", f"expected no runtime deps, got {deps.join(" ")}")
}

proc verify_managed_symlinks(rootfs: Path) [fs, error] {
  let bundle_link = fp"{rootfs}/etc/ssl/certs/ca-certificates.crt"
  ensure(bundle_link.is_symlink()?, "ca-certificates-layout", "canonical bundle is not a managed symlink")
  ensure(
    bundle_link.readlink()? == p"../../../var/lib/laputa/trust/active/ca-certificates.crt",
    "ca-certificates-layout",
    "canonical bundle symlink target changed",
  )

  let policy_link = fp"{rootfs}/etc/laputa/trust-policy"
  ensure(policy_link.is_symlink()?, "ca-certificates-layout", "canonical policy is not a managed symlink")
  ensure(
    policy_link.readlink()? == p"../../var/lib/laputa/trust/active/trust-policy",
    "ca-certificates-layout",
    "canonical policy symlink target changed",
  )

  let cert_link = fp"{rootfs}/etc/ssl/cert.pem"
  ensure(cert_link.is_symlink()?, "ca-certificates-layout", "cert.pem is not a symlink")
  ensure(cert_link.readlink()? == p"certs/ca-certificates.crt", "ca-certificates-layout", "cert.pem target changed")
}

proc verify_provisioned_key(rootfs: Path) [fs, error] {
  let key_path = fp"{rootfs}/etc/laputa/trust-update-key"
  ensure(key_path.exists()?, "ca-certificates-key", "missing provisioned trust-update key")
  let key = key_path.read_bytes()?
  ensure(key.len() == 32, "ca-certificates-key", "provisioned trust-update key must contain exactly 32 raw Ed25519 bytes")
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
  verify_managed_symlinks(rootfs)?
  verify_provisioned_key(rootfs)?
  verify_package_metadata(rootfs)?

  let paths = trust_store.trust_store_paths(rootfs)
  let seed_bundle = trust_store.seed_bundle_path(paths.root).read_bytes()?
  let seed_body = seed_bundle.utf8()?
  let cert_count = seed_body.split("-----BEGIN CERTIFICATE-----").len() - 1
  ensure(cert_count == 118, "ca-certificates-bundle", f"expected 118 certificates, found {cert_count}")
  ensure(
    "MIICTjCCAdOgAgIKPPYHqWhwDtqLhDAKB" not in seed_body,
    "ca-certificates-bundle",
    "bundle retains the removed emSign G3 root",
  )

  let active = trust_store.trust_store_bootstrap_from_seeds(rootfs)?
  ensure(active == "1", "ca-certificates-store", f"seeded trust generation is not 1: {active}")

  let bundle = trust_store.canonical_bundle_path(paths.root).read_bytes()?
  net.validate_root_bundle(bundle)?

  ensure(bundle == seed_bundle, "ca-certificates-store", "active bundle differs from the pinned seed")

  verify_distrust_policy(rootfs)

  print f"ca-certificates ok: {cert_count} certificates; emSign G3 root absent; 6 SPKIs blocked; store at generation {active}"
}
