set -eu
repo=$PWD
fixture="$repo/.work/tmp/bench-test-$$"
child=
cleanup() {
  if [[ -n $child ]]; then kill -- -"$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/repo/infra/asterinas" "$fixture/repo/.work/bench" "$fixture/seed" "$fixture/xsh"
git -C "$fixture/xsh" init -q
git -C "$fixture/xsh" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m pin
pin=$(git -C "$fixture/xsh" rev-parse HEAD)
printf 'XSH_COMMIT=%s\n' "$pin" > "$fixture/repo/infra/asterinas/inputs.lock"
for name in xsh xshi xsht core.tar.xz; do printf '%s\n' "$name" > "$fixture/seed/$name"; done
jaq -n --arg commit "$pin" --arg xsh "$(sha256sum "$fixture/seed/xsh" | cut -d' ' -f1)" --arg xshi "$(sha256sum "$fixture/seed/xshi" | cut -d' ' -f1)" --arg xsht "$(sha256sum "$fixture/seed/xsht" | cut -d' ' -f1)" --arg core "$(sha256sum "$fixture/seed/core.tar.xz" | cut -d' ' -f1)" '{xsh_commit:$commit,xsh_dirty:false,files:{xsh:$xsh,xshi:$xshi,xsht:$xsht,"core.tar.xz":$core}}' > "$fixture/seed/manifest.json"
export BENCH_XSH_ROOT="$fixture/xsh" BENCH_SEED="$fixture/seed"
cd "$fixture/repo"
support="$repo/bench/support.sh"
[[ $(bash "$support" verdict 0 105 100 5) == 'within budget' ]]
[[ $(bash "$support" verdict 0 106 100 5) == regression ]]
[[ $(bash "$support" verdict 0 106 - 0) == 'inconclusive: no anchor' ]]
[[ $(bash "$support" verdict 75 106 100 5) == 'inconclusive: host busy' ]]
printf '%s\n' '{"nodes":[{"name":"baselayout"}]}' > "$fixture/plan"
bash "$support" oracle 100 "$fixture/plan"
if bash "$support" oracle 0 "$fixture/plan"; then exit 1; fi
printf '%s\n' '{"nodes":[]}' > "$fixture/plan"
if bash "$support" oracle 100 "$fixture/plan"; then exit 1; fi
bash "$support" check tree-memory
for id in baselayout-1-1 musl-1.2.6-1 linux-headers-7.2.9-1; do
  dir="$fixture/repo/.out/artifacts/x86_64/v2/sha256/$(printf '%s' "$id" | sha256sum | cut -d' ' -f1)"
  mkdir -p "$dir"
  printf '%s' "$id" > "$dir/payload.tar.gz"
  hash=$(sha256sum "$dir/payload.tar.gz"); hash=${hash%% *}
  jaq -n --arg hash "$hash" --arg id "$id" '{package_id:$id,payload_sha256:$hash}' > "$dir/artifact.json"
done
bash "$support" check artifact-sizes
printf changed >> "$dir/payload.tar.gz"
if bash "$support" check artifact-sizes > "$fixture/package-stale"; then exit 1; fi
rg -q 'stale package' "$fixture/package-stale"
printf 'changed' >> "$fixture/seed/xsh"
if bash "$support" check tree-memory > "$fixture/stale"; then exit 1; fi
rg -q 'stale seed product xsh' "$fixture/stale"
if bash "$support" check world-plan > "$fixture/world-stale"; then exit 1; fi
rg -q 'stale seed product xsh' "$fixture/world-stale"
printf 'xsh\n' > "$fixture/seed/xsh"
jaq '.xsh_dirty = true' "$fixture/seed/manifest.json" > "$fixture/m"
mv "$fixture/m" "$fixture/seed/manifest.json"
if bash "$support" check tree-memory > "$fixture/dirty" 2>&1; then exit 1; fi
rg -q 'stale seed commit' "$fixture/dirty"
jaq '.xsh_dirty = false' "$fixture/seed/manifest.json" > "$fixture/m"
mv "$fixture/m" "$fixture/seed/manifest.json"
jaq '.xsh_commit = "0000000000000000000000000000000000000000"' "$fixture/seed/manifest.json" > "$fixture/m"
mv "$fixture/m" "$fixture/seed/manifest.json"
if bash "$support" check tree-memory > "$fixture/stale-commit" 2>&1; then exit 1; fi
rg -q 'stale seed commit' "$fixture/stale-commit"
setsid sleep 300 & child=$!
printf '%s\n' "$child" > .work/bench/test.pid
if bash "$support" check selection > "$fixture/child"; then exit 1; fi
rg -q 'surviving child process group' "$fixture/child"
rg -q 'nothing ran' "$fixture/child"
