# Divergence register

Intentional deviations from the C reference (`src/mdevd/mdevd.c`,
`src/mdevd/mdevd-coldplug.c`, `src/mdevd/mdevd_uevent_read.c`).
Everything else is byte-identical where the differential harness can
observe it: config acceptance, planned operations, CLI diagnostics,
event order, coldplug scan, readiness, and daemon publication bytes.
Test boundaries are in [local verification](testing.md).

## Hooks rejected (owner decision)

Reference spawns `/bin/sh` or `execlineb` for rules carrying commands
(`@`, `$`, `*`, `+`, `-`, `&`, and the empty-command quirk).

Rust v1 rejects any command-carrying line at parse with file, line, and
"hooks unsupported". Laputa's `mdev.conf` needs none.

Proof: `cargo test --locked -q -- config`, `cargo test --locked -q -- parity`
(`parity_config_acceptance` expects exit `2` here and `0` on the oracle).

## Firmware excluded (owner decision)

Reference loads firmware via `FIRMWARE=` events and `-F fwbase`.

Rust v1 logs `FIRMWARE=` events and skips them; `-F` exits non-zero naming
the exclusion. No reads of `/lib/firmware`, no writes to
`/sys/.../loading` or `/sys/.../data`.

Proof: `cargo test --locked -q --test engine --test bins`
(`engine_firmware_note`, `bins_firmware_flag_diverges`).

## Invalid reload retains last valid config

Reference exits `2` on a broken config after `SIGHUP`.

Rust keeps serving the last valid config, warns loudly, and stays alive.
Missing file keeps the reference behavior (warn plus catchall default);
a syntax error on initial load still exits `2`. `read` errors other than
`ENOENT` still exit `111`.

Proof: `cargo test --locked -q --test bins --test parity`
(`bins_hup_retain_diverges`, `parity_reload_matrix` FIFO handshake).

## Bounded coldplug sync

Reference `mdevd-coldplug -O` waits forever for the last triggered event.

Rust waits at most 60 seconds by default, overridden by
`MDEVD_COLDPLUG_SYNC_TIMEOUT_SECS`, and exits `1` loudly on timeout
instead of hanging boot.

Proof: `bins_coldplug_sync_timeout`, `parity_coldplug_tree`.

## Oversize config is an error

Reference reads at most `CONFBUFSIZE - 1` bytes and silently truncates.

Rust rejects input larger than 8191 bytes with "configuration too large"
and exits `2`. The bound matches `CONF_MAX` (`src/config/mod.rs`).

Proof: `config_too_large`, `parity_oversize_config_divergence`.

## Absolute and `..` paths refused in RealOps

Reference resolves absolute and `..`-carrying node paths after `chdir`
into the device root.

Every mutating `RealOps` method refuses absolute or `..`-carrying paths
loudly. Dry-run transcripts stay identical; real runs fail safe.

Proof: `cargo test --locked -q -- adversarial`, `engine_real_guards`.

## Existing nodes adopted only on matching identity

Reference `mknod` on `EEXIST` blindly `chmod`/`chown`s whatever is there.

`RealOps::mknod` on `EEXIST` opens the leaf with `O_PATH | O_NOFOLLOW`
and adopts it only when type and device identity match; anything else is
refused instead of re-owned.

Proof: `adversarial_device_adopts_only_matching_identity`,
`adversarial_device_replacement_cannot_redirect_metadata`.

## Symlink ancestors refused, metadata pinned to the verified inode

Reference re-resolves pathnames for every step, so a swapped ancestor or
leaf symlink can redirect `mkdir`, `unlink`, `mknod`, `chmod`, or `chown`.

Rust walks held non-symlink directory descriptors (`O_PATH | O_DIRECTORY
| O_NOFOLLOW`) for every intermediate component, retains the verified
device descriptor across `chmod`/`chown`, and refuses leaf symlinks.
`chmod` goes through `/proc/self/fd` so the device itself is never
opened. Requires a mounted `/proc/self/fd`.

Proof: `adversarial_mkdir_confines_ancestors`,
`adversarial_unlink_confines_ancestors`,
`adversarial_chmod_refuses_leaf_symlink`,
`adversarial_device_ancestor_symlink_and_permissions`,
`adversarial_device_root_replacement_preserves_directory_identity`,
`adversarial_device_replacement_cannot_redirect_metadata`,
`tools/check-privileged.sh` device cases.

## Sysfs fallback reads skip `..` escapes

Reference concatenates the sysfs root and device path without checks.

Rust skips `..`-carrying sysfs reads loudly and treats the fallback as
absent. Daemon dry runs still read sysfs through the same adapter.

Proof: `engine_sysfs_fallbacks`.

## Missing trailing newline ends the value

Reference does `strchr(devname, '\n')` without a NULL check when the
sysfs `uevent` file lacks a trailing newline.

Rust ends the `DEVNAME=` value at end of input instead.

Proof: `engine_sysfs_fallbacks`.

## Uevent framing validated without overruns

Reference classifies empty, unterminated, headerless, and oversized
records with warnings and drops userspace senders when intake filtering
is on; `MSG_TRUNC` is fatal and `ENOBUFS` is counted with a
"missed events" warning.

Rust keeps the same policy in a pure parser (`src/uevent/mod.rs`):
NUL-separated records plus trailing NUL, 8192 bytes and 63 variables,
`@/ ` anywhere satisfies the header check like `strstr`, duplicates
resolve first-wins, variable-less records drop, overruns are counted,
and `MSG_TRUNC` stays fatal. No `strlen` runs past the received bytes.

Proof: `cargo test --locked -q -- uevent`,
`adversarial_truncation_precedes_userspace_filter`,
`adversarial_spoof_flood_and_variable_limit`.

## Coldplug sync never dereferences missing fields

Reference `mdevd_uevent_getvar` returns NULL for a missing field and the
sync loop passes it to `strcmp` and `strrchr`, crashing on malformed
rebroadcast traffic.

Rust `sync_match` returns false when `ACTION`, `SUBSYSTEM`, or `DEVPATH`
is missing.

Proof: `bins_coldplug_cli`, `bins_coldplug_sync_match`, coldplug sync
timeout matrix.
