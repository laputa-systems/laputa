#!/bin/sh
## Disposable trust-update test fixtures. Never production keys.
##
## Generates everything under tests/pm/fixtures/trust-update/ with OpenSSL on a
## development machine: disposable Ed25519 signing keys, signed releases B
## (generation 2) and C (generation 3), a wrong-signer variant, a stale
## generation-1 re-statement, and TLS fixture PKI (test roots, servers, and a
## cross-signed intermediate pair sharing one SPKI). Private signing keys are
## NOT committed: only public keys, signatures, and certificates land in the
## repository. Rerun this script to refresh release expiries (releases expire
## at most 90 days after the wall-clock time observed here).
##
## The Laputa runtime never invokes OpenSSL; fixtures are inputs only.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=$ROOT
KEYS=$OUT/keys
REL_B=$OUT/release-b
REL_C=$OUT/release-c
REL_WRONG=$OUT/release-b-wrongsigned
REL_A=$OUT/release-a-stale
TLS=$OUT/tls

command -v openssl >/dev/null || { echo "need openssl on the fixture machine" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3 on the fixture machine" >&2; exit 1; }

mkdir -p "$KEYS" "$REL_B" "$REL_C" "$REL_WRONG" "$REL_A" "$TLS"
REL_D=$OUT/release-d
mkdir -p "$REL_D"

b64() { python3 -c 'import base64,sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())'; }
sha256hex() { python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

# Disposable Ed25519 signing keys Q (release signer), R (wrong signer), and
# S (rotated package key for the LAP-41 rotation proof).
# Fresh on every run: private halves are never committed, so regeneration
# rotates every fixture consistently.
openssl genpkey -algorithm ed25519 -out "$ROOT/.q.priv"
openssl pkey -in "$ROOT/.q.priv" -pubout -outform DER -out "$ROOT/.q.spki.der"
tail -c 32 "$ROOT/.q.spki.der" | b64 > "$KEYS/signing-key.public.base64"
cp "$ROOT/.q.priv" "$KEYS/.signing-key.private.tmp"
rm "$ROOT/.q.priv" "$ROOT/.q.spki.der"
openssl genpkey -algorithm ed25519 -out "$ROOT/.r.priv"
openssl pkey -in "$ROOT/.r.priv" -pubout -outform DER -out "$ROOT/.r.spki.der"
tail -c 32 "$ROOT/.r.spki.der" | b64 > "$KEYS/wrong-key.public.base64"
cp "$ROOT/.r.priv" "$ROOT/.rkey.tmp"
rm "$ROOT/.r.priv" "$ROOT/.r.spki.der"
openssl genpkey -algorithm ed25519 -out "$ROOT/.s.priv"
openssl pkey -in "$ROOT/.s.priv" -pubout -outform DER -out "$ROOT/.s.spki.der"
tail -c 32 "$ROOT/.s.spki.der" | b64 > "$KEYS/rotation-key.public.base64"
cp "$ROOT/.s.priv" "$ROOT/.skey.tmp"
rm "$ROOT/.s.priv" "$ROOT/.s.spki.der"
echo "fixture signing keys ready (private halves are NOT committed)"

# Test TLS PKI: roots A and B, servers, and a cross-signed intermediate pair.
mkca() {
  name=$1
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$TLS/$name.key" -out "$TLS/$name.crt" -days 3650 -nodes \
    -subj "/CN=$2" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" 2>/dev/null
}
mkserver() {
  name=$1
  ca=$2
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
    -keyout "$TLS/$name.key" -out "$TLS/$name.csr" -nodes \
    -subj "/CN=localhost" 2>/dev/null
  cat > "$TLS/.ext.cnf" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF
  openssl x509 -req -in "$TLS/$name.csr" -CA "$TLS/$ca.crt" -CAkey "$TLS/$ca.key" \
    -CAcreateserial -out "$TLS/$name.crt" -days 825 -extfile "$TLS/.ext.cnf" 2>/dev/null
  rm "$TLS/$name.csr" "$TLS/.ext.cnf"
}

mkca ca-a "Test Root A"
mkca ca-b "Test Root B"
mkca cross-r1 "Test Cross Root 1"
mkca cross-r2 "Test Cross Root 2"
mkserver server-a ca-a
mkserver server-b ca-b

## Guest-visible server: QEMU user-mode networking reaches the host loopback
## at 10.0.2.2, which must appear as an IP SAN for guest TLS validation.
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$TLS/server-guest.key" -out "$TLS/server-guest.csr" -nodes \
  -subj "/CN=laputa-guest-fixture" 2>/dev/null
cat > "$TLS/.ext.cnf" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1,IP:10.0.2.2
EOF
openssl x509 -req -in "$TLS/server-guest.csr" -CA "$TLS/ca-a.crt" -CAkey "$TLS/ca-a.key" \
  -CAcreateserial -out "$TLS/server-guest.crt" -days 825 -extfile "$TLS/.ext.cnf" 2>/dev/null
rm "$TLS/server-guest.csr" "$TLS/.ext.cnf"

# Cross-signed intermediate pair sharing one SPKI under two issuers.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TLS/inter.key" 2>/dev/null
openssl req -new -key "$TLS/inter.key" -out "$TLS/inter.csr" -subj "/CN=Test Leaf Intermediate" 2>/dev/null
cat > "$TLS/.ca-ext.cnf" <<'EOF'
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign,digitalSignature
EOF
openssl x509 -req -in "$TLS/inter.csr" -CA "$TLS/cross-r1.crt" -CAkey "$TLS/cross-r1.key" \
  -CAcreateserial -out "$TLS/inter-r1.crt" -days 825 -extfile "$TLS/.ca-ext.cnf" 2>/dev/null
openssl x509 -req -in "$TLS/inter.csr" -CA "$TLS/cross-r2.crt" -CAkey "$TLS/cross-r2.key" \
  -CAcreateserial -out "$TLS/inter-r2.crt" -days 825 -extfile "$TLS/.ca-ext.cnf" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$TLS/ee-cross.key" -out "$TLS/ee-cross.csr" -nodes -subj "/CN=localhost" 2>/dev/null
cat > "$TLS/.ee-ext.cnf" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -in "$TLS/ee-cross.csr" -CA "$TLS/inter-r1.crt" -CAkey "$TLS/inter.key" \
  -CAcreateserial -out "$TLS/ee-cross.crt" -days 825 -extfile "$TLS/.ee-ext.cnf" 2>/dev/null
# Unblocked control pair with the same shape.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TLS/control-inter.key" 2>/dev/null
openssl req -new -key "$TLS/control-inter.key" -out "$TLS/control-inter.csr" -subj "/CN=Test Control Intermediate" 2>/dev/null
openssl x509 -req -in "$TLS/control-inter.csr" -CA "$TLS/cross-r1.crt" -CAkey "$TLS/cross-r1.key" \
  -CAcreateserial -out "$TLS/control-inter.crt" -days 825 -extfile "$TLS/.ca-ext.cnf" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$TLS/ee-control.key" -out "$TLS/ee-control.csr" -nodes -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in "$TLS/ee-control.csr" -CA "$TLS/control-inter.crt" -CAkey "$TLS/control-inter.key" \
  -CAcreateserial -out "$TLS/ee-control.crt" -days 825 -extfile "$TLS/.ee-ext.cnf" 2>/dev/null
rm -f "$TLS"/*.csr "$TLS"/*.srl "$TLS"/.ext.cnf "$TLS"/.ca-ext.cnf "$TLS"/.ee-ext.cnf
cat "$TLS/ee-cross.crt" "$TLS/inter-r1.crt" > "$TLS/chain-cross-r1.pem"
cat "$TLS/ee-cross.crt" "$TLS/inter-r2.crt" > "$TLS/chain-cross-r2.pem"
cat "$TLS/ee-control.crt" "$TLS/control-inter.crt" > "$TLS/chain-control.pem"

BLOCKED_X=$(openssl pkey -in "$TLS/inter.key" -pubout -outform DER 2>/dev/null | sha256hex)
echo "blocked test SPKI: $BLOCKED_X"

SEED_BUNDLE=../../../../packages/ca-certificates/files/cacert.pem
SEED_POLICY=../../../../packages/ca-certificates/files/trust-policy
NOW=$(date -u +%s)
EXPIRES=$((NOW + 80 * 86400))

# Release B (generation 2): seed bundle plus test root A; policy keeps the six
# pinned hashes and blocks the cross-signed test intermediate SPKI.
cp "$SEED_BUNDLE" "$REL_B/ca-certificates.crt"
cat "$TLS/ca-a.crt" >> "$REL_B/ca-certificates.crt"
{
  echo "laputa-trust-policy-v1"
  echo "generation 2"
  grep "^blocked-spki-sha256" "$SEED_POLICY"
  echo "blocked-spki-sha256 $BLOCKED_X"
} > "$REL_B/trust-policy"
BUNDLE_B_HEX=$(sha256hex < "$REL_B/ca-certificates.crt")
POLICY_B_HEX=$(sha256hex < "$REL_B/trust-policy")
{
  echo "laputa-trust-release-v1"
  echo "generation 2"
  echo "expires-at $EXPIRES"
  echo "root-bundle-sha256 $BUNDLE_B_HEX"
  echo "trust-policy-sha256 $POLICY_B_HEX"
} > "$REL_B/metadata"
openssl pkeyutl -sign -inkey "$KEYS/.signing-key.private.tmp" -rawin -in "$REL_B/metadata" -out "$REL_B/metadata.sig"
[ "$(wc -c < "$REL_B/metadata.sig")" = "64" ] || { echo "bad signature length" >&2; exit 1; }

# Release C (generation 3): seed bundle plus test root B (root A removed).
cp "$SEED_BUNDLE" "$REL_C/ca-certificates.crt"
cat "$TLS/ca-b.crt" >> "$REL_C/ca-certificates.crt"
{
  echo "laputa-trust-policy-v1"
  echo "generation 3"
  grep "^blocked-spki-sha256" "$SEED_POLICY"
  echo "blocked-spki-sha256 $BLOCKED_X"
} > "$REL_C/trust-policy"
{
  echo "laputa-trust-release-v1"
  echo "generation 3"
  echo "expires-at $EXPIRES"
  echo "root-bundle-sha256 $(sha256hex < "$REL_C/ca-certificates.crt")"
  echo "trust-policy-sha256 $(sha256hex < "$REL_C/trust-policy")"
} > "$REL_C/metadata"
openssl pkeyutl -sign -inkey "$KEYS/.signing-key.private.tmp" -rawin -in "$REL_C/metadata" -out "$REL_C/metadata.sig"

# Stale generation-1 re-statement (same bytes as the pinned seeds).
cp "$SEED_BUNDLE" "$REL_A/ca-certificates.crt"
cp "$SEED_POLICY" "$REL_A/trust-policy"
{
  echo "laputa-trust-release-v1"
  echo "generation 1"
  echo "expires-at $EXPIRES"
  echo "root-bundle-sha256 $(sha256hex < "$REL_A/ca-certificates.crt")"
  echo "trust-policy-sha256 $(sha256hex < "$REL_A/trust-policy")"
} > "$REL_A/metadata"
openssl pkeyutl -sign -inkey "$KEYS/.signing-key.private.tmp" -rawin -in "$REL_A/metadata" -out "$REL_A/metadata.sig"

# Wrong-signer variant: B metadata signed by the wrong key.
cp "$REL_B/metadata" "$REL_WRONG/metadata"
cp "$REL_B/ca-certificates.crt" "$REL_WRONG/ca-certificates.crt"
cp "$REL_B/trust-policy" "$REL_WRONG/trust-policy"
openssl pkeyutl -sign -inkey "$ROOT/.rkey.tmp" -rawin -in "$REL_WRONG/metadata" -out "$REL_WRONG/metadata.sig"
rm -f "$ROOT/.rkey.tmp"

# Rotation generation 4: seed bundle plus both test roots, signed by the
# rotated package key S. The package update ships S plus these bytes as new
# seeds; releases still carry no keys (exact four files).
cp "$SEED_BUNDLE" "$REL_D/ca-certificates.crt"
cat "$TLS/ca-a.crt" >> "$REL_D/ca-certificates.crt"
cat "$TLS/ca-b.crt" >> "$REL_D/ca-certificates.crt"
{
  echo "laputa-trust-policy-v1"
  echo "generation 4"
  grep "^blocked-spki-sha256" "$SEED_POLICY"
  echo "blocked-spki-sha256 $BLOCKED_X"
} > "$REL_D/trust-policy"
{
  echo "laputa-trust-release-v1"
  echo "generation 4"
  echo "expires-at $EXPIRES"
  echo "root-bundle-sha256 $(sha256hex < "$REL_D/ca-certificates.crt")"
  echo "trust-policy-sha256 $(sha256hex < "$REL_D/trust-policy")"
} > "$REL_D/metadata"
openssl pkeyutl -sign -inkey "$ROOT/.skey.tmp" -rawin -in "$REL_D/metadata" -out "$REL_D/metadata.sig"
[ "$(wc -c < "$REL_D/metadata.sig")" = "64" ] || { echo "bad signature length" >&2; exit 1; }
rm -f "$ROOT/.skey.tmp"

# Expiry boundary variants over release B bytes (signed by Q).
REL_EXP=$OUT/release-expired
REL_FAR=$OUT/release-too-far
mkdir -p "$REL_EXP" "$REL_FAR"
BUNDLE_HEX=$(sha256hex < "$REL_B/ca-certificates.crt")
POLICY_HEX=$(sha256hex < "$REL_B/trust-policy")
{
  echo "laputa-trust-release-v1"
  echo "generation 2"
  echo "expires-at $((NOW - 86400))"
  echo "root-bundle-sha256 $BUNDLE_HEX"
  echo "trust-policy-sha256 $POLICY_HEX"
} > "$REL_EXP/metadata"
cp "$REL_B/ca-certificates.crt" "$REL_EXP/ca-certificates.crt"
cp "$REL_B/trust-policy" "$REL_EXP/trust-policy"
openssl pkeyutl -sign -inkey "$KEYS/.signing-key.private.tmp" -rawin -in "$REL_EXP/metadata" -out "$REL_EXP/metadata.sig"
{
  echo "laputa-trust-release-v1"
  echo "generation 2"
  echo "expires-at $((NOW + 91 * 86400))"
  echo "root-bundle-sha256 $BUNDLE_HEX"
  echo "trust-policy-sha256 $POLICY_HEX"
} > "$REL_FAR/metadata"
cp "$REL_B/ca-certificates.crt" "$REL_FAR/ca-certificates.crt"
cp "$REL_B/trust-policy" "$REL_FAR/trust-policy"
openssl pkeyutl -sign -inkey "$KEYS/.signing-key.private.tmp" -rawin -in "$REL_FAR/metadata" -out "$REL_FAR/metadata.sig"

rm -f "$KEYS/.signing-key.private.tmp"
echo "fixtures generated under tests/pm/fixtures/trust-update; private keys were not committed"
