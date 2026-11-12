#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$repo_root/infra/asterinas/run-cancellable.sh"
[[ $# == 4 ]] || { printf 'usage: build-native-fixture.sh XSH_CHECKOUT XSH_PRODUCTS TEST_IMAGE_ID OUTPUT_DIR\n' >&2; exit 2; }
xsh_source="$(realpath "$1")"
xsh_products="$(realpath "$2")"
test_image="$3"
mkdir -p "$(dirname "$4")"
output="$(realpath "$(dirname "$4")")/$(basename "$4")"
[[ "$test_image" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf 'native fixture requires an immutable Docker image ID\n' >&2; exit 2; }
[[ ! -e "$output" ]] || { printf 'native fixture output already exists: %s\n' "$output" >&2; exit 2; }
[[ -z "$(git -C "$xsh_source" status --porcelain=v1 --untracked-files=all)" ]] || { printf 'native fixture requires a clean XSH checkout\n' >&2; exit 2; }
xsh_commit="$(git -C "$xsh_source" rev-parse HEAD)"
for product in xsh xsht xshi; do
    [[ -x "$xsh_products/$product" ]] || { printf 'native fixture product missing: %s\n' "$product" >&2; exit 2; }
done
[[ -x /usr/local/bin/mold && -f "$xsh_source/dev/musl-linker.sh" ]] || { printf 'native fixture requires the qualified mold linker\n' >&2; exit 2; }
mkdir -p "$(dirname "$output")"
stage="$(mktemp -d "$(dirname "$output")/.native-fixture.XXXXXX")"
container=""
cleanup() {
    cancellable_stop
    if [[ -n "$container" ]]; then docker rm "$container" >/dev/null; fi
}
trap cleanup EXIT

git init --quiet "$stage/source"
git -C "$stage/source" fetch --quiet --depth=1 "$xsh_source" "$xsh_commit"
git -C "$stage/source" checkout --quiet --detach FETCH_HEAD
docker image inspect "$test_image" | jaq -r '.[0].Config.Env[]' > "$stage/image.env"
container="$(docker create --entrypoint /bin/true "$test_image")"
docker export --output "$stage/image.tar" "$container"
docker rm "$container" >/dev/null
container=""

cat > "$stage/build-root.sh" <<'BUILD'
set -euo pipefail
mkdir /stage/rootfs
tar -xf /stage/image.tar -C /stage/rootfs
rm /stage/image.tar
mkdir -p /stage/rootfs/work/target/x86_64-unknown-linux-musl/verification
cp -a /stage/source/. /stage/rootfs/work/
for product in xsh xsht xshi; do
    cp "/inputs/products/$product" "/stage/rootfs/usr/bin/$product"
    ln -sfn "/usr/bin/$product" "/stage/rootfs/work/target/x86_64-unknown-linux-musl/verification/$product"
done
cp /inputs/init /stage/rootfs/init
cp /inputs/linker /stage/rootfs/usr/local/bin/xsh-mold-linker
cp /inputs/mold /stage/rootfs/usr/local/bin/mold
chmod 755 /stage/rootfs/init /stage/rootfs/usr/local/bin/xsh-mold-linker /stage/rootfs/usr/local/bin/mold
cp /stage/image.env /stage/rootfs/etc/xsh-native.env
printf 'all\n' > /stage/rootfs/etc/xsh-native.selection
printf '127.0.0.1 localhost xsh-qualification\n::1 localhost ip6-localhost\n' > /stage/rootfs/etc/hosts
chown -R 1000:1000 /stage/rootfs/work
truncate -s 8G /stage/root.ext2
SOURCE_DATE_EPOCH=1 /sbin/mke2fs -q -F -t ext2 -L XSHNATIVE -d /stage/rootfs -E lazy_itable_init=0 /stage/root.ext2
/sbin/e2fsck -fn /stage/root.ext2
rm -r /stage/rootfs
BUILD

builder="laputa-native-fixture-build-$$"
run_cancellable "$builder" docker run --name "$builder" --rm --init --network none --cpus=2 --memory=4g --memory-swap=4g \
    --mount "type=bind,src=$stage,dst=/stage" \
    --mount "type=bind,src=$repo_root/guest/asterinas/native/init.sh,dst=/inputs/init,readonly" \
    --mount "type=bind,src=$xsh_products,dst=/inputs/products,readonly" \
    --mount "type=bind,src=$xsh_source/dev/musl-linker.sh,dst=/inputs/linker,readonly" \
    --mount type=bind,src=/usr/local/bin/mold,dst=/inputs/mold,readonly \
    --entrypoint /bin/bash "$test_image" /stage/build-root.sh
[[ -s "$stage/root.ext2" ]] || { printf 'native fixture builder produced no root image\n' >&2; exit 1; }

jaq -n --arg image "$test_image" --arg commit "$xsh_commit" \
    --arg root "$(sha256sum "$stage/root.ext2" | awk '{print $1}')" \
    --arg init "$(sha256sum "$repo_root/guest/asterinas/native/init.sh" | awk '{print $1}')" \
    --arg xsh "$(sha256sum "$xsh_products/xsh" | awk '{print $1}')" \
    --arg xsht "$(sha256sum "$xsh_products/xsht" | awk '{print $1}')" \
    --arg xshi "$(sha256sum "$xsh_products/xshi" | awk '{print $1}')" \
    '{format:"xsh-native-fixture-1", image:$image, xsh_commit:$commit, root_sha256:$root, init_sha256:$init, products:{xsh:$xsh,xsht:$xsht,xshi:$xshi}, uid:1000, gid:1000, jobs:1}' > "$stage/fixture.json"
rm -r "$stage/source"
chmod a-w "$stage/root.ext2"
mv "$stage" "$output"
printf 'native fixture: %s\n' "$output"
