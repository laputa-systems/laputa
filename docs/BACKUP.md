# Backups

R7 owns backup and restore for the maintained VM. The retained manual restore
drill in `tests/integration/restore_drill.py` is the primary proof: it backs up
`/etc /home /var`, removes the first repository key, restores a blank disk,
boots it, and checks identity, supervision, repository integrity, and the
re-backup difference. The scheduled path described here reuses the same
repository format, runner, and key material, but it does not replace that
manual drill.

## State ownership

- **Restored from the backup:** `/etc`, `/home`, and `/var`, including the
  Dropbear host key, operator accounts and authorized keys, the applied
  first-boot record, service state, and logs. Restoring these files restores
  the machine's identity; it is not a clone. A clone requires a distinct host
  key and identity document.
- **Reconstructed from the generation:** the kernel and `/usr`, which remain
  immutable generation content. A restore therefore needs the matching
  trusted image generation plus the repository.
- **Excluded:** any directory carrying a `.no-backup` marker. The marker is a
  file name, not a path; the shipped configuration uses `.no-backup`.

## Scheduled job

`qemu-maintained` ships two generation inputs:

- `/etc/laputa/timers/jobs.d/backup.json` schedules
  `/usr/bin/xsh /usr/lib/laputa/backup.xsh run` as a calendar job at 03:47 UTC
  daily. `overlap` is `skip`, `missed` is `coalesce`, the run timeout is one
  hour, and two retries follow a failed attempt after five minutes.
- `/etc/laputa/backup.json` holds the runner configuration. The managed
  `/etc` is the state disk, so provision that copy with the rest of the static
  configuration.

The runner:

1. validates the configuration and lists the repository snapshots. A missing
   target, key, or repository fails before any service is stopped.
2. runs the configured quiesce hook.
3. runs `rustic backup --exclude-if-present .no-backup /etc /home /var`.
4. runs `rustic check` over the repository and records the checked wall time.
5. runs `rustic forget --keep-last 3 --prune`.
6. writes a receipt and runs the release hook.

A failed quiesce, backup, check, prune, receipt write, or release exits
nonzero. Ordinary caught failures attempt the release hook. A killed or crashed
runner can bypass that epilogue and leave services stopped; recovery ownership
is open in [XSH-89](https://github.com/laputa-systems/xsh/blob/master/docs/rfc/XSH-89-backup-quiescence-recovery.md).

## Target and keys

The shipped configuration uses:

| Item | Path |
|---|---|
| Repository | `/mnt/backup/repo` |
| Password file | `/mnt/backup/keys/password` |
| Receipt | `/mnt/backup/repo/laputa-backup-receipt.json` |

The backup target must be mounted before the job fires; the runner does not
mount block devices. The password file and the repository must stay outside the
backup sources, and the loader refuses configurations where any of them
overlap. Tests use fixture passwords only.

The manual drill remains the authority for encryption-key recovery: it adds a
second password, exports the masterkey, removes the first key, proves the
removed password fails, and proves both the second key and the exported
masterkey recover access. `backup init` initializes a repository with the
configured single password for unattended operation; it does not replace that
ceremony, and an operator who needs recovery guarantees must run it.

## Retention

The policy is **keep the newest 3 snapshots** (`retention.keep_last`). The job
runs once a day, so the count is about three runs, not three guaranteed
calendar days: a missed or failed day is not backfilled. `keep-daily` was not
chosen because it would claim days for which no snapshot exists. Retention is
enforced with `rustic forget --keep-last 3 --prune`, and the runner verifies
that the new snapshot survived and that the repository retains no more than the
policy count before it writes a receipt.

## Quiescence

`/usr/lib/laputa/backup-quiesce.xsh` invokes xinit and waits for the observed
state. xinit queues each desired-state request and wakes the live scanner
through its control FIFO; without an active scanner, it applies the transition
directly. The shipped hook stops `logger` and `dhcp-eth0`, waits for
`desired=down` with a stopped, down, or dead state, and starts both on release
until they report running. It does not retain their prior desired states.
This bounds writes to `/var/log`, `/var/lib/dhcpc`, and `/etc/resolv.conf`
during the snapshot.

The timer scheduler is not stopped: it is the backup job's parent, and its
durable state is replaced atomically. A quiesced snapshot can still contain
scheduler state from an adjacent pass; the restore proof checks identity and
the configured application boundary, not every volatile byte.

## Receipt and restore binding

The receipt is `laputa-backup-receipt-1`, written atomically beside the
repository:

```json
{
  "format": "laputa-backup-receipt-1",
  "created_wall_ms": 1767225600000,
  "snapshot_id": "<64 hex characters>",
  "sources": ["/etc", "/home", "/var"],
  "keep_last": 3,
  "kept_snapshot_ids": ["<newest retained id>", "..."],
  "check": {"ok": true, "wall_ms": 1767225600100}
}
```

A restore binds to the receipt rather than to "latest": it requires the receipt
format, a successful recorded check, the named snapshot in the repository, the
retained set to be no larger than the policy and present in the repository, and
the named snapshot to be inside that set. Only then does it run
`rustic restore <snapshot_id> <blank-disk>`.

## Failure reporting

The runner never retries by itself. A nonzero exit becomes the timer job's
`last_outcome` and `last_exit_code`, and the failure counter advances. The job
definition's bounded retries are the only retries; a cancelled job starts
nothing and a running attempt is terminated. The guest proof observes the
failure in timer state, bounds it to the configured attempts, and shows that a
cancelled failing backup stops advancing its failure counter.

## Verification

- `tests/system/backup.xsh` checks the shipped job and configuration, retention
  decisions, receipt decoding and binding, snapshot JSON shapes, path overlap,
  and configuration rejection with the injected values.
- `tests/integration/backup_schedule.py` runs on a rebuilt `qemu-maintained`
  bundle under KVM: a timer interval job invokes the shipped runner, the
  fixture application is stopped at the snapshot boundary, the repository is
  checked, pruning leaves exactly `keep_last` snapshots, a bounded failing
  backup is reported through timer state, and a second boot restores the
  receipt's snapshot onto a blank disk and verifies identity and the quiesced
  writer boundary.
- `tests/integration/restore_drill.py` remains the primary manual restore
  proof, including the two-key and masterkey recovery checks.
