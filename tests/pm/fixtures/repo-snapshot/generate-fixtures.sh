#!/bin/sh
## Disposable repository-snapshot test fixtures. Never production keys.
##
## Generates everything under tests/pm/fixtures/repo-snapshot/ with OpenSSL on
## a development machine: disposable Ed25519 signing keys (current Q and
## rotation-next N, plus a wrong signer R), a fixture index.json, and signed
## snapshot metadata generations bound to that index. Private signing keys
## are NOT committed: only public keys, metadata, and signatures land in the
## repository. Expiries are fixed wall-clock constants; tests verify against
## explicit now values, so these fixtures never age out.
##
## The Laputa runtime never invokes OpenSSL; fixtures are inputs only.

set -eu

ROOT=$(CDPATH=; cd -- "$(dirname -- "$0")" && pwd)
OUT=$ROOT
KEYS=$OUT/keys
GEN1=$OUT/snapshot-gen1
GEN2=$OUT/snapshot-gen2
GEN2B=$OUT/snapshot-gen2b
WRONG=$OUT/snapshot-gen1-wrongsigned

command -v openssl >/dev/null || { echo "need openssl on the fixture machine" >&2; exit 1; }
command -v python3 >/dev/null || { echo "need python3 on the fixture machine" >&2; exit 1; }

mkdir -p "$KEYS" "$GEN1" "$GEN2" "$GEN2B" "$WRONG"

sha256hex() { python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }

# Fixed wall-clock constants. Tests pass explicit now values near NOW_REF.
# EXPIRES sits ~58 days after NOW_REF, inside the 90-day validity limit.
NOW_REF=1995000000
EXPIRES=2000000000

# Disposable Ed25519 keys: Q signs generation 1, N signs generation 2
# (the rotation target), R is a wrong signer. Fresh on every run; private
# halves are never committed.
openssl genpkey -algorithm ed25519 -out "$ROOT/.q.priv"
openssl pkey -in "$ROOT/.q.priv" -pubout -outform DER -out "$ROOT/.q.spki.der"
tail -c 32 "$ROOT/.q.spki.der" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())' > "$KEYS/signing-key.public.base64"
cp "$ROOT/.q.priv" "$ROOT/.qkey.tmp"
rm "$ROOT/.q.priv" "$ROOT/.q.spki.der"
openssl genpkey -algorithm ed25519 -out "$ROOT/.n.priv"
openssl pkey -in "$ROOT/.n.priv" -pubout -outform DER -out "$ROOT/.n.spki.der"
tail -c 32 "$ROOT/.n.spki.der" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())' > "$KEYS/next-key.public.base64"
cp "$ROOT/.n.priv" "$ROOT/.nkey.tmp"
rm "$ROOT/.n.priv" "$ROOT/.n.spki.der"
openssl genpkey -algorithm ed25519 -out "$ROOT/.r.priv"
openssl pkey -in "$ROOT/.r.priv" -pubout -outform DER -out "$ROOT/.r.spki.der"
tail -c 32 "$ROOT/.r.spki.der" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())' > "$KEYS/wrong-key.public.base64"
cp "$ROOT/.r.priv" "$ROOT/.rkey.tmp"
rm "$ROOT/.r.priv" "$ROOT/.r.spki.der"
echo "fixture signing keys ready (private halves are NOT committed)"

# Fixture index: the exact bytes the snapshot generations bind.
cat > "$OUT/index.json" <<'EOF'
[{"arch":"aarch64","artifact_key":"fixture-artifact-key","deps":[],"executor_sha256":"","metadata":"","metadata_sha256":"","metapackage":false,"mkdeps_host":[],"mkdeps_target":[],"name":"fixture","proof":"","proof_key":"","proof_receipt_sha256":"","proof_sha256":"","recipe_sha256":"","rel":"1","runtime_only_deps":[],"sha256":"fixture-payload","size":42,"source_sha256":"","tarball":"","ver":"1"}]
EOF
INDEX_HEX=$(sha256hex < "$OUT/index.json")
echo "fixture index sha256: $INDEX_HEX"

# Second fixture index: same shape, different bytes. Generation 2b binds it
# to prove a same-generation re-issue under different bytes is rejected.
python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("fixture-payload", "rotated-payload"))' < "$OUT/index.json" > "$OUT/index2.json"
INDEX2_HEX=$(sha256hex < "$OUT/index2.json")
echo "fixture index2 sha256: $INDEX2_HEX"

sign_with() {
  key_tmp=$1
  src=$2
  dest=$3
  openssl pkeyutl -sign -inkey "$key_tmp" -rawin -in "$src" -out "$dest"
  [ "$(wc -c < "$dest")" = "64" ] || { echo "bad signature length" >&2; exit 1; }
}

{
  echo "laputa-repo-snapshot-v1"
  echo "generation 1"
  echo "expires-at $EXPIRES"
  echo "index-sha256 $INDEX_HEX"
} > "$GEN1/metadata"
sign_with "$ROOT/.qkey.tmp" "$GEN1/metadata" "$GEN1/metadata.sig"

{
  echo "laputa-repo-snapshot-v1"
  echo "generation 2"
  echo "expires-at $EXPIRES"
  echo "index-sha256 $INDEX_HEX"
} > "$GEN2/metadata"
sign_with "$ROOT/.nkey.tmp" "$GEN2/metadata" "$GEN2/metadata.sig"

cp "$GEN1/metadata" "$WRONG/metadata"
sign_with "$ROOT/.rkey.tmp" "$WRONG/metadata" "$WRONG/metadata.sig"

{
  echo "laputa-repo-snapshot-v1"
  echo "generation 2"
  echo "expires-at $EXPIRES"
  echo "index-sha256 $INDEX2_HEX"
} > "$GEN2B/metadata"
sign_with "$ROOT/.nkey.tmp" "$GEN2B/metadata" "$GEN2B/metadata.sig"

rm -f "$ROOT/.qkey.tmp" "$ROOT/.nkey.tmp" "$ROOT/.rkey.tmp"
echo "fixtures generated under tests/pm/fixtures/repo-snapshot; private keys were not committed"
echo "reference now for tests: $NOW_REF (expires $EXPIRES)"
