# Testing

Tested with XSH `master` at `b69f21f1448a590fd4f8469f1e31ede305265668`
(`ssh.Certainty`), built with `cargo build -p xsh --bin xsh -p xsht`.
Re-run the suite and update this pin before relying on a newer XSH.

```sh
export PATH=/path/to/xsh/target/verification:$PATH     # xsh and xsht from XSH master
export TMPDIR=$PWD/.work/tmp
xsht check lib bin tests examples fixtures packaging
xsht test --jobs 16                                    # fixture tests skip without hosts
```

The xsh dialect suite runs the catalogue's XSH sources through the `xsh` on
PATH, so the verification build must stay on PATH for the whole run.

## Disposable Alpine container hosts

```sh
xsh fixtures/alpine.xsh build                          # builds xinfra-fixture:alpine-3.22 (needs docker and network)
xsh fixtures/alpine.xsh up --count 3                   # writes .work/fixtures/inventory.toml
XINFRA_TEST_INVENTORY=$PWD/.work/fixtures/inventory.toml xsht test --jobs 8
xsh fixtures/alpine.xsh down
```

Each container runs OpenSSH (Ed25519 host and client keys generated fresh per
run), BusyBox, doas, OpenRC and `shadow`, and is reached on its Docker bridge
address; nothing is published on the host network. The inventory defines, per
container, `fx-N` (login `deploy`, doas), `fx-N-root` (login root) and
`fx-N-plain` (login `plain`, doas not permitted). `down` removes exactly the
containers `up` recorded. The suites use `fx-1` for file work, `fx-2` for
packages, accounts and services, and `fx-3` for two-process cancellation, so an
apply being signalled does not race another suite's package or service work.

## Disposable Alpine VM

A real Alpine guest under QEMU/KVM exercises the same suites with OpenRC as PID
1. The base image is pinned by URL and sha256 in `fixtures/alpine-vm.xsh` and
cached under `.work/fixtures/vm/cache`; each guest boots a copy-on-write overlay
so the base stays pristine. `up` starts at most two VMs, waits for cloud-init,
asserts `/proc/1/comm` is `init` and that `sshd` is started in the default
runlevel, then writes `.work/fixtures/vm/inventory.toml` in the same format as
the container fixture.

```sh
xsh fixtures/alpine-vm.xsh up --count 2                # writes .work/fixtures/vm/inventory.toml
export XINFRA_TEST_INVENTORY=$PWD/.work/fixtures/vm/inventory.toml
for suite in files system commands failures processes; do
  xsht test "tests/test-alpine-$suite.xsh" --jobs 2
done
xsh fixtures/alpine-vm.xsh down

xsh fixtures/alpine-vm.xsh up --count 1 --first 3      # names the one VM fx-3
XINFRA_TEST_INVENTORY=$PWD/.work/fixtures/vm/inventory.toml xsht test tests/test-alpine-cancel.xsh --jobs 1
xsh fixtures/alpine-vm.xsh down
```

`fx-1` and `fx-2` cover the per-resource suites; `--first 3` names the single VM
`fx-3` so the cancellation suite runs without a third guest. The inventory
defines, per VM, `fx-N` (login `deploy`, doas), `fx-N-root` (login root) and
`fx-N-plain` (login `plain`, doas not permitted). VMs are reached through a
loopback host-forward.

Each guest gets a cloud-init NoCloud seed from a loopback `python3 -m
http.server`; QEMU's built-in vvfat driver exposes only 8.3 names and so cannot
carry `user-data`. The seed server is stopped after cloud-init finishes, and
`down` kills any recorded seed server and QEMU process and removes the guest's
work directory. The fixture needs `qemu-system-x86_64` with KVM, `qemu-img`,
`python3`, `ssh`, `ssh-keygen` and `ssh-keyscan`; the guest needs network access
for cloud-init's `apk add doas shadow` and for the package suites. The base
image download also needs network the first time.

## Suites

| File | Covers |
|---|---|
| `test-shell`, `test-transport` | Quoting round trip with hostile values, argument/stdin/binary transport, signal and timeout classification, certainty from the native client's typed errors, `connect_all`, and a dead session after a timeout. |
| `test-declare`, `test-graph`, `test-inventory` | Validation at declaration, ordering, cycles, duplicate ids, cross-host operation merge, inventory inheritance and errors. |
| `test-probe`, `test-compare` | Parsing every host report; one verdict per resource kind, including conflicts, uncertainty and redaction. |
| `test-report`, `test-lock` | Sanitizing, redaction, exit statuses, JSON/JSONL shape; lock ownership, contention, token release. |
| `test-engine-local`, `test-engine-semantics` | Apply, idempotence, drift, plan/check purity, validator failure, blocked dependents, failure policies, barriers, job bound, trigger coalescing, secrets, hostile paths, stale plans, unknown outcomes. |
| `test-xinit-adapter`, `test-xsh-dialect` | The xinit adapter against a fake POSIX `xinit`: start, restart, stop, an unknown service and a denied status, through observe, compare, apply and verify. The xsh dialect: hostile argument round trip through a real `xsh`, XSH sources checked against the POSIX facts for paths and xinit services, typed refusal of operations the dialect lacks, and a local xsh-host apply that creates, updates, retargets and removes a directory, file and symlink and controls an xinit service. |
| `test-cli`, `test-install` | Exit statuses 0/1/2, report formats, validation before mutation, install tree contents. |
| `test-transport-ssh`, `test-alpine-*` | The same behaviors against real OpenSSH and Alpine: hostile names through the login shell, doas and refused doas, a wrong host-key pin, a 40 MiB artifact, a 600 MiB transfer cut off by its timeout, accounts, packages (versions, out-of-band removal, an unavailable package), OpenRC reload coalescing, a stopped service repaired, a failed validation that never restarts a service, every command condition, failing commands and hostile arguments, unreachable and unauthenticated hosts, a host failing midway beside a healthy one, concurrent applies, SIGKILL and SIGTERM of the controller. |
| `test-alpine-cancel` | Two-process cancellation of a running `apply` on `fx-3` with every boundary held from the target side: a blocking command resource before and after each resource kind, plus an in-flight request for a command, a streamed file transfer and a service reload. Each case signals only the controller, checks the deferred stderr report and that the host lock is free, then removes the hold and re-runs to convergence. |

The `test-alpine-*` suites run against either fixture. The container fixture
uses `rc_sys=docker`; the VM fixture is a real guest whose PID 1 is OpenRC
`init` and whose `sshd` comes from the default runlevel.

The Laputa xsh dialect is not part of the committed fixture suite: it needs a
qemu-maintained generation and the lifecycle provisioning in
`laputa/tests/integration/g2_lifecycle.py`. The qualified run and what it
covered are recorded in the [matrix](MATRIX.md).

## Cancellation boundaries

Every boundary is held on the target; the controller carries no test hook. A
blocking `command` resource is placed before or after the resource under test.
Its script writes a marker and waits for a hold file to disappear. "Before" is
that gate ahead of the resource, so a signalled apply reports the resource
`blocked`. "After" is the same gate behind it, so the resource is already
recorded `changed` and a re-run does not replay it. An "in-flight" case holds a
request that has an observable interior: a command that waits on a hold file, a
40 MiB streamed file, and an OpenRC reload hook. The test signals only the
controller, checks the deferred outcome report on stderr (the resource being
reconciled is `unknown`, later resources are `blocked`, completed resources keep
their recorded outcome), checks the lock is free, then releases the hold and
re-runs. Atomic single-request operations (one `mkdir`, `ln -s`, `addgroup`,
`adduser`, `apk add`, `apk update`) have no separately holdable interior; their
before and after boundaries are covered by the gates.

Run the Alpine suites more than once: every test is written to converge from
whatever state an earlier run left. The same holds on the VM fixture, which can
be torn down and started again with the same commands.

## Differential against pyinfra

```sh
xsh fixtures/pyinfra.xsh build                         # pip installs pyinfra 3.5 (needs network)
xsh fixtures/pyinfra.xsh diff                          # all scenarios on fx-2; or --scenario packages
```

Needs `fixtures/alpine.xsh up`. It starts one extra Alpine container for
pyinfra and removes it on exit. The scenarios and their outcomes are in
[the comparison](PYINFRA.md). Do not run it while the Alpine suites run: both
change packages and services on `fx-2`.
