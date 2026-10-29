#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .work/tmp
scratch=$(mktemp -d "$PWD/.work/tmp/check-deps.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/bin"
cat > "$scratch/bin/cargo" <<'SCRIPT'
#!/bin/sh
case "$TREE_CASE" in
  failed) echo 'cargo tree failed' >&2; exit 42 ;;
  valid) printf '%s\n' 'mdevd v0.1.0' 'libc v0.2.191' ;;
  forbidden) printf '%s\n' 'mdevd v0.1.0' 'libc v0.2.191' 'unexpected v1.0.0' ;;
esac
SCRIPT
chmod +x "$scratch/bin/cargo"
for tree_case in failed forbidden; do
  if PATH="$scratch/bin:$PATH" TREE_CASE="$tree_case" /bin/sh tools/check-deps.sh > "$scratch/output" 2>&1; then
    echo "check-deps accepted $tree_case" >&2
    exit 1
  fi
done
PATH="$scratch/bin:$PATH" TREE_CASE=valid /bin/sh tools/check-deps.sh > "$scratch/output" 2>&1
echo 'check-deps rejects failed trees and forbidden dependencies'
