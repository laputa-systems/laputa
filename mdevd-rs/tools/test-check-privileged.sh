#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
script=${1:-$PWD/tools/check-privileged.sh}
mkdir -p .work/tmp
scratch=$(mktemp -d "$PWD/.work/tmp/privileged-status.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/tools" "$scratch/bin"
cp "$script" "$scratch/tools/check-privileged.sh"
cat > "$scratch/bin/cargo" <<'STUB'
#!/bin/sh
jaq -nc '{reason:"compiler-artifact",profile:{test:true},executable:"/stale-test"}'
exit "${TEST_BUILD_STATUS:?}"
STUB
cat > "$scratch/bin/docker" <<'STUB'
#!/bin/sh
printf '%s\n' invoked >> "${TEST_DOCKER_LOG:?}"
STUB
chmod +x "$scratch/bin/"*
for status in 0 1; do
  log="$scratch/docker-$status"
  if PATH="$scratch/bin:$PATH" TEST_BUILD_STATUS=$status TEST_DOCKER_LOG="$log" \
    /bin/sh "$scratch/tools/check-privileged.sh" > "$scratch/output" 2>&1; then
    [ "$status" -eq 0 ] || { cat "$scratch/output"; exit 1; }
    [ "$(wc -l < "$log")" -eq 2 ]
  else
    [ "$status" -ne 0 ] || { cat "$scratch/output"; exit 1; }
    [ ! -e "$log" ]
  fi
done
printf '%s\n' 'privileged build status regression passed'
