#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 && -d "$1" ]] || { printf 'usage: cargo-input-digest.sh ASTERINAS_SOURCE_DIR\n' >&2; exit 2; }
cd "$1"
sha256sum Cargo.lock osdk/Cargo.lock .cargo/config.toml | sha256sum | awk '{print $1}'
