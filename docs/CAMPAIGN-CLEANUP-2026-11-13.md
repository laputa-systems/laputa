# Campaign cleanup — 2026-11-13

Reclaimed **37,163,888,640 allocated bytes (34.6 GiB)** by deleting seven
obsolete generated VM disks. The mechanic lane verified integration and
inventory; the parent completed the host consumer checks and deletions.
The worker's isolated PID namespace could not perform the host checks itself.
Filesystem free-space changes from other activity are not attributed to this pass.

| Deleted disk | Allocated bytes |
|---|---:|
| `.work/tmp/ioprio-selectors-standard-proof/root.ext2` | 8590114816 |
| `.work/tmp/ioprio-selectors-single-nice-after/root.ext2` | 8590147584 |
| `.work/tmp/setpgid-exec-standard-proof/root.ext2` | 3999285248 |
| `.work/tmp/termios-before-control/root.ext2` | 3995160576 |
| `.work/tmp/silent-server-owned-listener-6c752b269/root.ext2` | 3999281152 |
| `.work/wt/native-qualification-fixture/.work/tmp/native-fixture/root.ext2` | 3994951680 |
| `.work/wt/native-qualification-fixture/.work/tmp/native-fixture-final/root.ext2` | 3994947584 |

The privileged host scan inspected 432 processes in the host PID namespace,
including command lines, mappings, mounts, cwd/root/executable links and file
descriptors. It found no references or permission errors. Every disk was a
regular file, older than the live run, and its identity, size and modification
time were revalidated before unlinking. All seven paths are confirmed absent.
Logs, kernels, binaries and source were retained.

Three completed, integrated worktrees were retired with `worktree-retire`:
`native-accounting`, `native-fatal-cancellation`, and
`native-qualification-fixture`. Their useful ignored evidence moved to
`.work/archive/winddown-20261113/`. Each was clean and an ancestor of main
`310180c9`; the tool applied its normal integration checks.

The accepted XSH deadline worktree and the two completed kernel review worktrees
were also retired after preserving their results. The cleanup worker checkout
is retired after this report is committed. Unverified kernel implementation
branches remain parked; their refs are also preserved in the owning
`asterinas` repository, independently of scratch checkouts.

The current kernel cache stays: main `.cache/asterinas` resolves into
`.work/wt/final-asterinas/.cache/asterinas`. The `final-asterinas` checkout is
therefore retained as a current cache consumer. Unreviewed caches in
`ownership-readlink-qualification` and `upstream-consumers` also stay.

Preserved inputs include the interrupted full native run, both current immutable
native bases, the four prepared ACL/priority proof roots, their kernel artifacts,
current standard/main TCP proofs, the latest maintained replay, and the legacy
Linux reference archive. The active run and both queued proof drivers were
stopped for the owner's winddown; their status is interrupted/canceled, not pass.

Eighteen older XSH and eight Laputa lanes had uncommitted source. They were saved
as local `parked/winddown/20261113/*` snapshots, with the original branch and
revision in each commit body. These snapshots are unverified and unmerged.
Historical worktrees remain for their retained source and resume inputs.
Nothing was pushed during winddown.

Supporting evidence is at `.work/tmp/cleanup-disk-20261113/`:
`finish-consumers.txt`, `removed-disks.txt`, `laputa-park-consumers.txt`, and
`laputa-parked-sources.txt`. The current resume status is in XSH's
`dev/campaign/HANDOFF-2026-11-12.md`.
