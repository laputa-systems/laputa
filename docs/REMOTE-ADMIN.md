# Remote administration

`system/remote.xsh` administers one Laputa machine from another host over XSH's
native SSH client. It owns Laputa policy only; the transport, host-key checks and
streams belong to XSH ([native SSH](https://github.com/laputa-systems/xsh/blob/master/docs/ssh.md)).
It never runs `ssh`.

## Design

- **A fixed program.** Every request runs `system/remote_guest.xsh`. The admin
  host sends that exact text as the SSH exec command, so the operator's login
  shell (`xsh-login`) runs it; no request value is ever interpolated into shell
  or XSH source.
- **A bounded, versioned request.** Stdin starts with one JSON header line of at
  most 4,096 bytes carrying `protocol: "laputa-remote-1"` and an `op`. A `stage`
  request then carries exactly `size` payload bytes. The program answers with one
  JSON line and exits zero whenever it produced an answer, so a nonzero exit or a
  missing completion is a transport fault, never a refusal.
- **Operator authority.** The program runs as the first-boot operator and uses
  only that account's access. Reads work without elevated authority; a log the
  operator cannot read is reported as `readable: false`.

## Operations

| Library call | Guest operation | Behavior |
|---|---|---|
| `remote_inspect` | `inspect` | running generation receipt, health report, xinit service states, hostname, kernel |
| `remote_run` | `run` | an explicit argv without a shell; exact exit status, signal, bounded stdout and stderr |
| `remote_stage`, `remote_digest` | `stage` | stream a file into `~/staging`, verify size and the caller's SHA-256, publish without replacing |
| `remote_staged` | `staged` | whether a name is staged, its digest, and any scratch files a failed transfer left |
| `remote_diagnose`, `remote_diagnose_afresh` | `diagnose` | unhealthy services and bounded log tails |

Staging verifies size and digest only. The digest should come from a trusted
receipt, not from the file just sent, and verified staging is not an authenticity
claim: package admission and activation stay with the PM and `system/activation.xsh`.

A refused or interrupted transfer leaves no file. A name that already holds the
same bytes reports `present`; one that holds different bytes is refused.

## Failures and unknown outcomes

A returned `ssh.exec` result contains exit status, signal, missing-completion
status and captured output. It carries no certainty field: the request was
submitted. `remote.ExecResult` uses the same fields.

`ssh.exec` reports an `SshError` whose `certainty` says whether the request may
have reached the machine. After any failure the session is unusable. The library
never retries and never reconnects. After a `submitted` failure, open a fresh
session and reconcile (`remote_staged`, `remote_inspect`) before deciding. Closing
a connection does not prove a remote process stopped.

## Qualification

`tests/system/remote_guest.xsh` runs the guest program as a script and covers
refusals, bounded input and the staging contract. `tests/integration/remote_admin.py`
boots the maintained x86_64 image headless under KVM, provisions an operator, an
authorized key and a pinned Dropbear host key on the state disk, and runs
`tests/integration/fixtures/remote-admin-drill.xsh` over a forwarded port:

```sh
python3 tests/integration/remote_admin.py --xsh PATH/TO/xsh --dropbearkey PATH/TO/dropbearkey \
  [--bundle target/laputa/qemu-maintained/current]
```

The xsh must be one that has the XSH-55 `ssh` module (`ssh.info`, `SshError`, `known_hosts`) and
the opaque `SshSession` handle; an older host xsh cannot check `system/remote.xsh`. `RemoteSession`
is that handle: it cannot be built from a record or shown, so a caller keeps the value
`remote_connect` returns. Text from the guest (a failed program's stderr, a refusal's kind and
message) reaches errors with its control and escape characters removed.

The drill pins the host key provisioned for `identity restore`, refuses a wrong
one before authentication, inspects the generation and services, runs an explicit
argv and a failing one, stages and re-stages a candidate, refuses a wrong digest,
interrupts a transfer by deadline and reconciles it from a fresh session, and
collects diagnostics naming the dead service. It does not cover macOS or
aarch64 clients, reboot identity, network loss, privilege delegation or
activation of the staged candidate.

`tests/integration/ssh_network_recovery.py` qualifies the same client over the
network under test rather than a forwarded port. A scripted DHCPv4 server
declares one address on a tap owned by an unprivileged user+network namespace,
and the client connects to that address inside the namespace with the pinned
Dropbear host key. After link loss, lease expiry and re-acquisition, a supervised
`dhcp-eth0` restart, and NIC reappearance on a new ifindex, it requires a fresh
verified connection to recover on the declared address and reads the guest's own
`xinit status dhcp-eth0` there. The same run proves the profile's IPv6 policy:
the packaged drop-in disables IPv6 autoconfiguration, no IPv6 address or route
exists, and the status reports `ipv6=unsupported` explicitly. It does not add
IPv6 support.

`tests/integration/g2_lifecycle.py` reuses this library for the roadmap G2
inspect/run/stage/diagnose and link-loss work on the same maintained guest (see
[maintained activation](QEMU.md#maintained-vm-activation)). Its supervised
`xinit restart` calls run as the non-root `probe` operator; first boot adds that
account to the reserved `xinit-admin` group, which authorizes `start`, `stop`,
`restart`, and `reload` through xinit's verified control inbox. No UID 0
administrator is provisioned. The drill also does not establish macOS or
aarch64 clients.

The harness formats the state disk with `system/maintained_state_image.xsh`, so the
operator keeps the id `first_boot.apply` allocates (1001 beside baselayout's `laputa`)
and owns `home/admin`, `.ssh` and `authorized_keys` in the image.
