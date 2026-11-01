#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
selection='core/tests/test-dhcp-net.xsh::test_a_fresh_lease_adds_the_address_then_the_default_route'
XSH_TEST="$selection" make -C "$repo_root" asterinas-test
rg -Fq -- "$selection ... ok" "$repo_root/.out/asterinas-firecracker/test-console.log"
