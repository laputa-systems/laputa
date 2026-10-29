#!/bin/xsh
# Example xinit integration for mdevd-rs (Laputa argv shape).
# Starts the Rust daemon with the canonical Laputa invocation, then runs
# the serial coldplug step. Replace /etc/mdev.conf with your ruleset.
# See tests/fixtures/laputa-invocation.txt for provenance.

mdevd -O 4 -f /etc/mdev.conf -C
mdevd-coldplug -O 4
