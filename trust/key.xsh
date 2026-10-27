##! Installed trust-update verification key handling.

use trust.store as trust_store

## Provisioned verification key loading failed fail-closed.
## TrustKeyError.
export error TrustKeyError = InvalidData(message: Str)

## Loads the raw 32-byte Ed25519 trust-update public key.
export proc trust_key_load(system_root: Path) [fs, error] -> Result[Bytes, Error] {
  let key_path = trust_store.provisioned_key_path(system_root)
  guard key_path.exists()? else {
    return Err(
      TrustKeyError.InvalidData(
        "no trust-update verification key is provisioned at /etc/laputa/trust-update-key; provision one per docs/CERTIFICATE-TRUST.md before updating trust",
      ),
    )
  }

  let key = key_path.read_bytes()?
  guard key.len() == 32 else {
    return Err(
      TrustKeyError.InvalidData(
        f"provisioned trust-update key must contain exactly 32 raw Ed25519 bytes, found {key.len()}",
      ),
    )
  }

  key
}

## Fingerprint of a provisioned key for status reporting.
export pure trust_key_fingerprint(key: Bytes) -> Str {
  key.sha256().hex()
}
