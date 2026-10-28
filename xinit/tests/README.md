# Exercise lifecycle ownership in disposable guests

Use the supplied fixed XSH snapshot and the existing `xsh-test` Docker image.
The snapshot must contain `bin/xsh` and matching `core/` sources, including the
optional module condition fix. Run from the Laputa checkout root:

```bash
xinit_snapshot=/absolute/path/to/fixed-xsh
python3 xinit/tests/fixtures/signal_storm.py \
  --tools "$xinit_snapshot/bin" --xsh-root "$xinit_snapshot" --seed 43
```

Missing Docker, the image, or the tools fails the command. `.work/` must already
be ignored by Git. Sources and tools are read-only, and scratch uses `.work/tmp`.
Containers run as the caller's UID/GID with no capabilities, a read-only root,
no network, one CPU, 512 MiB, and a 64-process limit. Successful runs remove
scratch. Failure diagnostics remain for inspection.

The scanner oracle runs as PID 1 in its disposable namespace. It starts the
production scanner without native fakes or a test opt-in. Retired dry-run and
gated fake-PID/event flags are deliberately present and must remain inert.
Configuration checks reject malformed declarations before runtime paths or
worker events exist. Inspection redacts commands, and planning orders dependencies.

Each service forks a descendant in its owned group. Only the leader owns the
readiness notifier. The descendant retains the instance lock to expose a live
orphan after leader death. A separate group checks foreign-process identity.
Final namespace census includes zombies and children that exited before writing
an event. The scanner must reap every owned child before returning.

A seed chooses restart, stop/start, leader crash, readiness-pipe closure, and
readiness timeout actions. Each action waits for observable reconciliation.
Every sequence runs with both SIGTERM and SIGINT shutdown. Use `--steps N` for
one to sixteen actions. Replay the printed action prefix directly:

```bash
python3 xinit/tests/fixtures/signal_storm.py \
  --tools "$xinit_snapshot/bin" --xsh-root "$xinit_snapshot" --replay crash
```

Use the explicit scanner-restart replay to check a fresh process clock origin:

```bash
python3 xinit/tests/fixtures/signal_storm.py \
  --tools "$xinit_snapshot/bin" --xsh-root "$xinit_snapshot" \
  --replay crash,scanner-restart,timeout-ready
```

Interrupt scanner startup and a held finish hook at controlled barriers:

```bash
python3 xinit/tests/fixtures/signal_storm.py \
  --tools "$xinit_snapshot/bin" --xsh-root "$xinit_snapshot" --mode boundaries
```

The startup barrier leaves a dependent unstarted while its provider awaits
readiness. Neither stop nor finish may run for that dependent. The finish barrier
holds an actual hook, delivers SIGTERM or SIGINT, then releases the hook.
Cleanup must complete before the scanner returns.

Verify the inittab engine as actual namespaced PID 1:

```bash
python3 xinit/tests/fixtures/signal_storm.py \
  --tools "$xinit_snapshot/bin" --xsh-root "$xinit_snapshot" --mode pid1
```

HUP must exec the restart hook as PID 1. USR1 must select halt, USR2 and INT
poweroff, and TERM reboot. Owned groups must be reaped before lifecycle hooks.
With zero effective capabilities, terminal kernel calls must fail with EPERM
and their distinct `linux-*` error kind. This checks dispatch and cleanup
without reboot capability. Actual PID 1 must ignore supplied test overrides.

Reduce a failing action replay automatically:

```bash
python3 xinit/tests/fixtures/signal_storm.py \
  --tools "$xinit_snapshot/bin" --xsh-root "$xinit_snapshot" \
  --mode shrink --replay restart,crash,stop-start
```

The reducer removes the unexecuted suffix, then tries at most eight deletions
with a shared 120-second trial budget. It preserves the failed phase and invariant
signature. Infrastructure failures never become accepted reductions. An empty
replay checks startup/shutdown alone. Reduction retains the original failing exit
status and prints `REDUCED`; it does not turn a failure into a pass.

Fixed seeds replay actions and observation boundaries, not kernel scheduling.
Each scanner observation has a six-second deadline. Scanner container runs have
a 180-second outer limit. PID 1 cases bound startup to six seconds and exit to
15 seconds after the signal. Docker control calls have ten-second limits.
The host launcher removes containers on success, failure, and timeout.

Run native regressions with the same fixed snapshot:

```bash
XSH_ROOT="$xinit_snapshot" XSH_MODULE_PATH="$PWD" \
  "$xinit_snapshot/bin/xsht" test --jobs 1 xinit/tests
```

Run `clock_budget_guest.xsh` only inside the existing headless self-hosting VM
supervisor. It requires the `LAPUTA_SELF_HOSTING=1` kernel marker and the canonical
`qemu-self-hosting` generation receipt. It changes the guest wall clock and
restores it after cleanup. Never run it on the host or grant Docker SYS_TIME.
Inside that disposable VM, invoke:

```bash
XSH_MODULE_PATH=/mnt/self-hosting/inputs/laputa XSH_ROOT=/usr/lib/xsh \
  /usr/bin/xsh /mnt/self-hosting/inputs/laputa/xinit/tests/fixtures/clock_budget_guest.xsh
```

At `LAP27_PAUSE_READY`, the supervisor stops QEMU, rejects a premature
`LAP27_RESUME_OBSERVED`, waits three seconds, and continues QEMU. The guest reports
clock deltas without assuming pause accounting. Require `LAP27_BUDGETS_OK` and
`LAP27_CLOCK_OK`, plus the supervisor's successful stop/continue acknowledgments.
The actual x86_64 KVM run passes wall-step budgets and wall restoration. With a
three-second host pause during its two-second sleep, it reports 2001 monotonic
milliseconds and 2000 wall milliseconds; that backend excludes the host pause
from these guest deltas.

Run the leader-crash counterexample in that same disposable VM:

```bash
XSH_MODULE_PATH=/mnt/self-hosting/inputs/laputa XSH_ROOT=/usr/lib/xsh \
  /usr/bin/xsh /mnt/self-hosting/inputs/laputa/xinit/tests/fixtures/lifecycle_replay_guest.xsh
```

The canonical scanner must reap the same-group descendant before finish and
respawn. A second case replaces exactly one cleanup call with an empty group
list in a private runtime copy. It must expose the same surviving-descendant
invariant as the native replay. Require `LAP34_VM_CANONICAL`,
`LAP34_VM_NEGATIVE invariant=surviving-owned-descendant prefix=crash`, and
`LAP34_VM_OK`. The final marker follows both cases' group cleanup. The actual
x86_64 KVM self-hosting VM emits all three markers: the canonical scanner cleans
up before finish and respawn, and the deliberately wrong runtime copy exposes
the surviving owned descendant. The native replay also rejects the original
implementation and that empty-group repair.

These Linux x86_64 proofs do not qualify scanner SIGKILL, disk power loss,
Asterinas, or architecture parity. The Python oracle uses the standard library
already in `xsh-test`; installed packages gain no Python dependency.

## Qualify the DHCP client in a disposable VM

`xinit/tests/fixtures/dhcp_vm_host.xsh` boots a KVM guest from a staged
initramfs (a static musl `xsh`, its `core/` tree and the `dhcp_*_guest.xsh`
fixtures) with a kernel you supply, and drives it over QMP. Run it from this
checkout with `XSH_ROOT` holding `bin/xsh` and `core/`:

```bash
XSH_MODULE_PATH="$XSH_ROOT/core" xsh xinit/tests/fixtures/dhcp_vm_host.xsh \
  "$XSH_ROOT" "$KERNEL" .work/tmp/dhcp-vm/pause pause 45
```

The scenarios are `pause SECONDS [QEMU_ARGUMENT...]` (QMP `stop`, wait, `cont`
while a 60 s lease is bound), `wall` (the guest steps its wall clock a day
forward and two days back) and `nic` (a carrier flap with `set_link`, then the
guest removes and rescans its virtio-net device). Each prints one `HOSTRESULT`
JSON line of measurements; none is a pass condition. The guests mutate the
clock and the PCI bus, so they refuse to run anywhere but this disposable
machine. The numbers and what they do and do not show are in the xsh
repository's `docs/TESTING.md`.
