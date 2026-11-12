#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
mkdir -p "$repo_root/.work/tmp"
export TMPDIR="$repo_root/.work/tmp"
work="$(mktemp -d "$TMPDIR/xsh-target.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/snapshot-one" "$work/snapshot-two" "$work/.out/xsh-target"
printf 'preserved legacy cache\n' > "$work/.out/xsh-target/legacy"
printf '#include <stdio.h>\nint main(void) { puts("first-api"); }\n' > "$work/snapshot-one/main.c"
printf '#include <stdio.h>\nint main(void) { puts("second-api"); }\n' > "$work/snapshot-two/main.c"
touch -t 200001010000 "$work/snapshot-one/main.c" "$work/snapshot-two/main.c"
cat > "$work/build.mk" <<'MAKE'
$(TARGET): $(SOURCE)
	$(CC) $(SOURCE) -o $(TARGET)
MAKE
first_hash="$(sha256sum "$work/snapshot-one/main.c" | awk '{print $1}')"
second_hash="$(sha256sum "$work/snapshot-two/main.c" | awk '{print $1}')"
ln -s "$work/snapshot-one" "$work/active"
bash "$repo_root/infra/asterinas/select-xsh-target.sh" "$work" "$first_hash"
make --silent -f "$work/build.mk" "SOURCE=$work/active/main.c" "TARGET=$work/.out/xsh-target/program"
[[ "$("$work/.out/xsh-target/program")" == first-api ]]
first_binary="$(sha256sum "$work/.out/xsh-target/program" | awk '{print $1}')"
rm "$work/active"
ln -s "$work/snapshot-two" "$work/active"
make --silent -f "$work/build.mk" "SOURCE=$work/active/main.c" "TARGET=$work/.out/xsh-target/program"
[[ "$("$work/.out/xsh-target/program")" == first-api ]]
bash "$repo_root/infra/asterinas/select-xsh-target.sh" "$work" "$second_hash"
make --silent -f "$work/build.mk" "SOURCE=$work/active/main.c" "TARGET=$work/.out/xsh-target/program"
[[ "$("$work/.out/xsh-target/program")" == second-api ]]
second_binary="$(sha256sum "$work/.out/xsh-target/program" | awk '{print $1}')"
[[ "$first_binary" != "$second_binary" ]]
bash "$repo_root/infra/asterinas/select-xsh-target.sh" "$work" "$first_hash"
[[ "$("$work/.out/xsh-target/program")" == first-api ]]
[[ "$(sha256sum "$work/.out/xsh-target/program" | awk '{print $1}')" == "$first_binary" ]]
legacy_files=("$work"/.out/asterinas-firecracker/xsh-targets/legacy.*/legacy)
[[ ${#legacy_files[@]} == 1 && "$(cat "${legacy_files[0]}")" == 'preserved legacy cache' ]]
printf 'asterinas-xsh: preserved-mtime source switches select distinct reusable binaries\n'
