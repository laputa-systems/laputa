# Trust-update test fixtures

Disposable fixtures for the signed trust-update tests. Nothing here is
trusted by production: production trusts only the provisioned key at
`/etc/laputa/trust-update-key` and releases it verifies.

- `keys/*.public.base64` — disposable Ed25519 verification keys. The matching
  private halves are deliberately NOT committed; they exist only on the
  offline fixture-generation machine. `rotation-key` is the rotated package
  key for the LAP-41 rotation proof; it never signs releases under the
  superseded `signing-key`.
- `release-b/`, `release-c/` — signed generations 2 and 3 over modified
  bundles/policies (test roots added, one removed). `metadata.sig` files
  are raw 64-byte Ed25519 signatures.
- `release-d/` — signed generation 4 under `rotation-key` over the seed
  bundle plus both test roots. The simulated OS package update ships the
  rotated key plus these bytes as new seeds, then `trust update` converges
  to generation 4. Releases carry no keys: exactly four files with the same
  metadata, signature, bundle, and policy shape as every other release.
- `release-b-wrongsigned/` — release B metadata signed by the wrong key.
- `release-a-stale/` — signed generation-1 re-statement for replay tests.
- `tls/` — disposable TLS PKI for fixture HTTPS servers (test CAs, server
  certificates, a cross-signed intermediate pair sharing one SPKI, and an
  unblocked control pair). `server-guest.crt` carries an IP SAN for
  10.0.2.2 so QEMU user-mode guests can validate the host fixture server.
  Private `*.key` files ARE committed because the fixture servers need
  them at test time; they are random test-only keys with no production
  relationship. `chain-*.pem` files are server chains (end-entity plus
  intermediates) for the fixture server.

Regeneration is all-or-nothing: `generate-fixtures.sh` rotates signing keys,
releases, and TLS PKI together, because release policies pin test SPKI
hashes. Rerun it to refresh release expiries (releases expire at most 90
days after generation). Never regenerate piecemeal and never commit a
private *signing* key.
