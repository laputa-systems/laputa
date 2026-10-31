# Trust, secrets, and privilege

## Host trust

Every inventory host needs a `SHA256:` host-key fingerprint. xinfra does not
read `~/.ssh/known_hosts`, accept an unknown key, or fall back to a prompt.
The connection fails before authentication when the presented key differs.

Generate a deployment key and install its public half on the guest:

```sh
ssh-keygen -t ed25519 -N "" -f keys/deploy_ed25519
ssh-copy-id -i keys/deploy_ed25519.pub deploy@203.0.113.10
chmod 600 keys/deploy_ed25519
```

Read the guest fingerprint from the key the SSH daemon presents:

```sh
ssh-keyscan -t ed25519 203.0.113.10 2>/dev/null |
  ssh-keygen -lf - | awk '{print $2}'
```

Put that value in the inventory `host_key` field. The first connection does not
trust on first use. A rotation requires a new pin.

The native client requires strict key exchange, `curve25519-sha256`, an
Ed25519 host key, and an Ed25519 user key. It does not use SSH agents,
passwords, keyboard-interactive authentication, certificates, PTYs, port
forwarding, or SFTP.

The inventory rejects a key path outside the inventory directory, a missing
key, a non-file key, and a key readable by group or others. Keep keys at mode
`0600`.

## Secrets

A deployment stores a reference, never a value:

```xsh
model.File(model.FileSpec(
  id: "token",
  path: p"/etc/app/token",
  source: model.Secret(model.FromEnv("APP_TOKEN")),
  mode: 0o600,
  owner: "root",
  group: "root",
  privilege: model.AsRoot,
))
```

`model.FromEnv(NAME)` reads the controller environment at apply time.
`model.FromFile(PATH)` reads a local file at apply time. A file source must be
mode `0600` or stricter; group- or world-readable files are rejected.

Secrets reach only file content or command stdin. They never enter argv, the
remote environment, plans, reports, or saved artifacts. Staged secret content
is written with mode `0600`, and report rendering replaces every known secret
with `[redacted]` in human, JSON, and JSONL output. A changed secret file is
compared by digest; an unchanged digest is a no-op.

Environment secrets are visible to the controller process and its
environment. Prefer `FromFile` when the controller environment is shared.

## Privilege

A resource declares `privilege: model.AsRoot` when it writes a root-owned path
or manages an account, package, or service. The remote driver detects
passwordless `doas -n`, then `sudo -n`, once per connection. If neither works
and the connection is not root, the action fails with the observed state; it
never reports success.

For `doas`, allow the deployment user to run commands without a password:

```sh
# /etc/doas.conf
permit nopass deploy as root
```

For `sudo`:

```sh
# /etc/sudoers.d/xinfra
deploy ALL=(root) NOPASSWD: ALL
```

Use a narrower rule when the deployment only needs specific commands. xinfra
does not install or configure `doas` or `sudo`; the operator installs and tests
the rule.

The trusted-parent check runs before a create or replace. A group- or
world-writable parent must be sticky and owned by the declared owner.
Traversal components are rejected, and a managed path never climbs above the
path written in the deployment.

## Failure boundaries

A host-key or authentication failure occurs before any mutation. A timeout
before a request is submitted is `not submitted`. A timeout or disconnect after
submission is `submitted` or `unknown`, never success. xinfra does not retry a
mutation after submission.
