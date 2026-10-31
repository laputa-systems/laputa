# Platform support

## Qualified remote baseline

| Component | Qualified value |
|---|---|
| Guest OS | Alpine Linux 3.23.4 |
| Shell | `/bin/sh` (BusyBox ash) |
| Core utilities | BusyBox 1.37 |
| Package manager | `apk` |
| Service manager | OpenRC |
| SSH server | OpenSSH 10.x |
| Account tools | shadow `useradd`, `usermod`, `userdel`, `groupadd`, `groupdel` |
| Path metadata | `stat -c`, `mv -T`, `sha256sum`, `mktemp`, `getent` |
| Privilege | passwordless `doas` or `sudo` |

Remote commands run with `LC_ALL=C` and:

```
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

`xinfra doctor` validates the inventory and deployment and lists the selected
hosts. The `transport` integration case probes the baseline above on both
fixtures.

## Controller support

| Controller | Status | Notes |
|---|---|---|
| macOS arm64 | Qualified | Full `make check`, `make test`, `make integration`, and `make differential`. |
| Linux x86_64 | Qualified | Ubuntu 24.04; full `make check`, `make test`, and integration suite with the pinned `x86_64-unknown-linux-musl` release pair. |
| Linux arm64 | Not qualified | No arm64 controller was available. |

The controller needs an XSH release that includes the `ssh` module. The shipped
wrapper runs `${XSH:-xsh}` and does not embed a controller binary.

The Linux controller ran the integration suite against the same macOS-hosted
aarch64 Alpine fixtures. The guest baseline stays Alpine 3.23.4; controller
architecture is independent of guest architecture.

## Capability matrix

| Capability | Controller | Remote guest |
|---|---|---|
| Inventory parsing | Yes | No |
| Deployment module loading | Yes | No |
| Template rendering | Yes | No |
| Typed validation and planning | Yes | No |
| Secret resolution | Yes | No |
| Native SSH transport | Yes | No |
| Directory, file, symlink apply | Yes | Staging, promotion, and metadata commands |
| `apk` packages | Yes | `apk` |
| Users and groups | Yes | shadow account tools |
| Commands | Yes | `/bin/sh` and the command itself |
| OpenRC services | Yes | `rc-service`, `rc-update` |
| Facts | Yes | POSIX tools |
| Locks | Yes | Lock directory operations |
| Reports | Yes | No |
| Python, pyinfra, or an agent | No | No |

## Architecture

```
inventory.toml ─┐
deploy.xsh ─────┼─> typed model ─> validation ─> pure planner ─> actions
local artifacts ┘                                      │
                                                       v
                                             host driver or fake HostOps
                                                       │
                                                       v
                                             native SSH / POSIX commands
```

The deployment module is declaration-only. The loader resolves local artifacts
and templates before touching a host. The planner is pure and returns ordered
`Action` values. Applying an action uses either the local fake boundary in tests
or the remote driver in production.

The native SSH client lives in XSH. It uses the vendored OxiSH packet and key
exchange code with Graviola as the only cryptographic provider. It negotiates
strict key exchange, pins a `SHA256:` host key, authenticates an Ed25519 key,
and streams channel data with bounded windows.

## Deliberate omissions

- No Python, pyinfra, agent, or daemon on the managed guest.
- No systemd, apt, dnf, or non-Alpine package adapter.
- No PTY allocation, port forwarding, SFTP, agent forwarding, password
  authentication, keyboard-interactive authentication, or SSH certificates.
- No host-key algorithm other than Ed25519 and no user key other than an
  unencrypted Ed25519 OpenSSH key.
- No Dropbear, BSD SSH, or older OpenSSH adapter. An unsupported server fails
  clearly instead of guessing.
- No automatic retry after a submitted mutation.
- No file-content capture in reports or plans.
- No background reconciliation or periodic drift loop.
