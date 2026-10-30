#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=$(CDPATH= cd -- "$ROOT/../../../.." && pwd)
EXCLUDE=$(git -C "$REPOSITORY" rev-parse --path-format=absolute --git-path info/exclude)
rg -q '^\.work/$' "$EXCLUDE" || printf '\n.work/\n' >> "$EXCLUDE"
mkdir -p "$REPOSITORY/.work/tmp"
WORK=$(mktemp -d "$REPOSITORY/.work/tmp/repo-snapshot.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$ROOT/keys"

for key in signing-key next-key wrong-key; do
  openssl genpkey -algorithm ed25519 -out "$WORK/$key.private"
  openssl pkey -in "$WORK/$key.private" -pubout -outform DER -out "$WORK/$key.der"
  tail -c 32 "$WORK/$key.der" | openssl base64 -A > "$ROOT/keys/$key.public.base64"
done

jaq -cn '[{arch:"aarch64",artifact_key:("a" * 64),deps:[],executor_sha256:("b" * 64),metadata:"aarch64/fixture-metadata.json",metadata_sha256:("c" * 64),metapackage:false,mkdeps_host:[],mkdeps_target:[],name:"fixture",proof:"aarch64/fixture-proof.json",proof_key:("d" * 64),proof_receipt_sha256:("e" * 64),proof_sha256:("f" * 64),recipe_sha256:("a" * 64),rel:"1",runtime_only_deps:[],sha256:("b" * 64),size:42,source_sha256:"",tarball:"aarch64/fixture-payload.tar.gz",ver:"1"}]' > "$ROOT/index.json"
jaq -c '.[0].tarball |= sub("fixture-payload"; "rotated-payload")' "$ROOT/index.json" > "$ROOT/index2.json"

sign_snapshot() {
  directory=$1
  generation=$2
  index=$3
  key=$4
  mkdir -p "$ROOT/$directory"
  digest=$(openssl dgst -sha256 -r "$ROOT/$index" | cut -d ' ' -f 1)
  printf 'laputa-repo-snapshot-v1\ngeneration %s\nexpires-at 2000000000\nindex-sha256 %s\n' "$generation" "$digest" > "$ROOT/$directory/metadata"
  openssl pkeyutl -sign -inkey "$WORK/$key.private" -rawin -in "$ROOT/$directory/metadata" -out "$ROOT/$directory/metadata.sig"
}

sign_snapshot snapshot-gen1 1 index.json signing-key
sign_snapshot snapshot-gen2 2 index.json next-key
sign_snapshot snapshot-gen2b 2 index2.json next-key
sign_snapshot snapshot-gen1-wrongsigned 1 index.json wrong-key
