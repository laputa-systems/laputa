#!/bin/sh
set -eu

volume=$1
source=$2
destination=$3
platform=$4
image=$5

docker volume create "$volume" >/dev/null
docker run --rm --platform "$platform" --entrypoint /bin/sh -v "$volume:$destination" "$image" \
    -c 'find "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' sh "$destination"
tar -C "$source" --exclude=target -cf - . |
    docker run --rm --platform "$platform" -i --entrypoint /bin/sh -v "$volume:$destination" "$image" \
    -c 'tar -xf - -C "$1"' sh "$destination"
