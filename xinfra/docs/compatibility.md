# pyinfra compatibility

This page records how xinfra behaves relative to the reference deployment
tool. It is a reference, not a promise that every pyinfra option exists here.

## Reference

| Item | Value |
|---|---|
| pyinfra | 3.10.0 |
| Python | 3.13 |
| License | MIT |
| Install location | `.work/oracle/venv`, disposable and never shipped |
| Reference host | `xinfra-a`, Alpine 3.23.4 |
| Candidate host | `xinfra-b`, Alpine 3.23.4 |

`dev/differential.xsh` resets both guests, applies the same resources with
pyinfra to `xinfra-a` and with xinfra to `xinfra-b`, normalizes the resulting
state, and compares it. A second apply checks no-op behavior. A missing package
checks failure behavior. pyinfra runs with an isolated `HOME`; xinfra connects
with its own pinned host key.

The pyinfra inventory uses its SSH connector. xinfra uses the native `ssh`
module. Neither the controller nor the guest installs Python for xinfra.

## Compared operations

| pyinfra operation | xinfra resource | Compared state |
|---|---|---|
| `files.directory` | `DirectorySpec` | type, mode, owner, group |
| `files.put` | `FileSpec` with content | mode, owner, group, size, SHA-256 |
| `apk.packages` | `PackageSpec` | installed version |
| `server.group` | `GroupSpec` | gid |
| `server.user` | `UserSpec` | uid, gid, home, shell, primary group |
| `server.shell` | `CommandSpec` | file produced by the command |
| `openrc.service` | `ServiceSpec` | running state, enabled state |

The first apply reports every resource changed in both tools. The second apply
reports every resource unchanged except the unguarded command, which both tools
run again. A request for a missing package fails in both tools.

## Deviations

| Area | pyinfra | xinfra |
|---|---|---|
| Host trust | Reads `known_hosts` and accepts an unknown key by default | Requires a `SHA256:` pin and rejects a mismatch |
| Transport | Paramiko on the controller | Native SSH with strict key exchange and Graviola |
| Remote runtime | Python and pyinfra facts on the guest | POSIX shell, BusyBox, and `apk` only; no Python |
| Parent directories | `files.directory` creates missing parents | A managed directory requires a trusted existing parent |
| File replacement | Backs up or force-replaces by flag | Stages beside the destination, verifies, then `mv -T` |
| File validation | No staged validator | `Validation.argv` runs against the staged file before promotion |
| User updates | Changes uid, gid, home, shell, and groups by default | Changes groups, home, and shell only with `update: true`; refuses uid and gid changes |
| User removal | Removes the account | Preserves a non-empty home and reports `blocked` |
| Package versions | `latest`, `update`, and `upgrade` flags | Exact or suffixed constraint; index refresh only when `refresh_index` is true |
| Command guards | Unconditional shell commands | `creates`, `unless_argv`, and `always_run`; plan never executes a guard |
| Service status | Reads `rc-status` for the default runlevel | Reads `rc-service status` directly |
| Failure policy | Stops the run on the first failed operation | `isolate`, `abort`, or `continue`, with per-host outcomes |
| Saved plans | No versioned approval artifact | Version-1 artifact with source, deployment, inventory, version, observation, and action checks |
| Secrets | Inventory variables and templates | Env or file references resolved only at apply time; never in plans or reports |

## Verified pyinfra quirks

`openrc.service(..., enabled=False)` starts the service on every run when it is
already running. pyinfra reads `rc-status default`, which omits a disabled
service, so its status fact reports the service as absent. xinfra reads
`rc-service status` and treats the running, disabled service as unchanged.
`dev/integration/services.xsh` independently verifies the intended stopped,
disabled, and enabled states.

BusyBox `adduser -G GROUP` sets the primary gid but also adds the user to the
group member list. shadow `useradd -g GROUP` sets only the primary gid. xinfra
uses `useradd`, `usermod`, `userdel`, `groupadd`, and `groupdel` so primary
group membership matches the reference and `getent group` output.

## Running the check

```sh
make differential
```

The target creates the pinned pyinfra environment when it is missing, starts
the disposable fixtures, and runs the differential. It does not install
anything on a fixture.
