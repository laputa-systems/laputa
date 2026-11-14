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
  OxiSH host key (`/etc/oxish/host_ed25519_key`), operator accounts and the
  `/etc/oxish/accounts` login keys, the applied
  first-boot record, service state, and logs. Restoring these files restores
  the machine's identity; it is not a clone. A clone requires a distinct host
  key and identity document. A restored host key must keep owner root and mode
  `0600`: `oxish-server` refuses a looser key, `oxish-hostkey` never replaces
  an existing key, and the restore drill hashes both OxiSH files before and
  after.
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
runner can bypass that epilogue; the timer supervisor then restores the
services (see Quiescence). Quiescence runs only under the supervisor: start a
backup by hand with `xsh /usr/lib/laputa/timers.xsh run-now backup`, not by
running `backup.xsh run` yourself, which refuses to quiesce.

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

`/usr/lib/laputa/backup-quiesce.xsh stop SERVICE...` runs inside a supervised
attempt. It first writes a durable record
`/var/lib/laputa-timers/quiesce/JOB.json` (`laputa-quiesce-1`): the job, an
ownership token, the boot id, each service's prior desired state, and the
recovery bounds below. Only services whose desired state was `up` are
acquired; a service that was already down stays down and is never started. The
record is synced before the first stop. Each acquired service is then stopped
with `xinit stop --owner TOKEN`, and the hook waits for `desired=down`.

`start SERVICE...` (the release hook) and the supervisor's
`backup-quiesce.xsh reconcile JOB` do the same thing: for each acquired
service, read xinit's `SERVICE.control`. Only when it still names the token is
the stop handed back with `xinit start --if-owner TOKEN`; xinit checks the
owner and applies the start in one scanner pass
([control ownership](../xinit/docs/SUPERVISION.md#control-ownership)). A
service an operator stopped or started after acquisition, or one the attempt
never stopped, is left exactly as it is. A request queued in the inbox is waited
out before the owner is judged. The record is removed only after every acquired
service is released, and a repeat costs no transition. A release that fails
keeps the record.

If the backup job is lost (timeout, cancellation, SIGKILL, scheduler restart)
the supervisor settles the attempt's writer first and then releases the record
([Timers](TIMERS.md#writer-identity)).

The recovery bound is published in the `quiesce` command of
`profiles/qemu-maintained/etc/laputa/backup.json` and copied into the record:

| Flag | Shipped | Meaning |
|---|---|---|
| `--timeout-ms` | 30000 | Per service stop or start transition. |
| `--recover-timeout-ms` | 60000 | One release attempt, per service. |
| `--recover-retry-ms` | 30000 | Wait between the supervisor's release attempts. |
| `--recover-attempts` | 5 | Failed release attempts before the record is left for an operator. |

With these defaults and the two shipped services, a lost job is detected within
0.5 s, its writer is proven stopped within 4 s, and the release that follows
takes seconds when xinit answers and at most 60 s per service (120 s) when it
does not, so services are back within about 125 s in the worst first attempt. A release that keeps
failing is retried up to 5 times, 30 s apart, which bounds the whole recovery
at 4 + 5 x (120 + 30) = 754 s, after which the record is left in place and
logged as `quiesce-release-exhausted`.
The shipped hook timeouts (90 s and 130 s) stay above these bounds, which
`tests/system/backup.xsh` checks. Restarting the supervisor starts a fresh
attempt count. An operator can release by hand with
`xsh /usr/lib/laputa/backup-quiesce.xsh reconcile backup`.

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
