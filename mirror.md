Replace the current janky `.deb` + `scp` mirror deployment with a deliberately small, Unix-native, idempotent deployment system.

The end state must be:

```sh
make deploy-mirror
```

and that command should safely converge the production mirror to the desired state.

The host target is "oracle". ssh ubuntu@oracle works.

Do not introduce a deployment framework. This should be implemented in straightforward POSIX shell on top of SSH, systemd, normal filesystem primitives, and Cloudflare's new `cf` CLI.

## Philosophy / constraints

This project has a very high bar for infrastructure dependencies. Prefer transparent Unix primitives over frameworks.

Explicitly do **not** introduce:

- Nix/NixOS
- Ansible
- Terraform/OpenTofu
- Kamal
- deploy-rs
- Kubernetes
- Docker/Podman on the production host
- systemd-sysupdate
- a deployment daemon/agent
- a state database for deployment
- Wrangler
- locally-managed Cloudflare Tunnel configuration

The production host should remain a boring Debian/Ubuntu-style systemd Linux box.

SSH is good. systemd is good. Atomic filesystem operations are good. Small shell scripts are good.

The deployment code itself must be POSIX `sh`, not Bash.

Use:

```sh
#!/bin/sh
set -eu
```

No Bash arrays, `[[ ]]`, process substitution, `${foo//...}`, `pipefail`, or other Bashisms. It must run under macOS `/bin/sh` locally and a normal Debian `/bin/sh` remotely.

Shellcheck with `-s sh` where useful.

## Current state

Inspect the repository first and preserve anything that has changed since this prompt was written.

At present, the deployment path is approximately:

```text
mirror-build-x86_64-musl
mirror-frontend
        ↓
build .deb
        ↓
scp .deb to DEPLOY_HOST
        ↓
dpkg -i
systemctl daemon-reload
systemctl restart laputa-mirror
```

The mirror already builds as a static MUSL Rust binary.

The frontend build produces the `mirror/static` tree.

The current service runs the binary with a working directory containing that `static` tree.

Production configuration currently includes roughly:

```text
LISTEN_ADDR
S3_ENDPOINT
S3_BUCKET
S3_ACCESS_KEY_ID
S3_SECRET_ACCESS_KEY
S3_REGION
DB_PATH
UPLOAD_DIR
ALLOWED_USERS
RP_ID
RP_ORIGIN

optional JWT_* settings
optional R2_PUBLIC_URL
```

The current production architecture is:

```text
Cloudflare Tunnel
    ↓
127.0.0.1:3000
    ↓
laputa-mirror
    ↓
Cloudflare R2
```

Preserve that architecture.

## Desired deployment architecture

The host should look approximately like this:

```text
/opt/laputa-mirror/
├── releases/
│   ├── <release-id>/
│   │   ├── laputa-mirror
│   │   └── static/
│   └── ...
└── current -> releases/<release-id>

/var/lib/laputa-mirror/
├── auth.db
└── uploads/

/etc/laputa-mirror/
├── env
└── credentials/
    ├── s3-access-key-id
    └── s3-secret-access-key

/etc/laputa-cloudflared/
└── token

/etc/systemd/system/
├── laputa-mirror.service
└── laputa-cloudflared.service

/etc/sysusers.d/
└── laputa-mirror.conf
```

No application files should be installed into `/usr/bin`, `/usr/share`, etc.

The application release is immutable once installed.

Only `/opt/laputa-mirror/current` changes to activate a release.

Persistent application state remains under `/var/lib/laputa-mirror`.

## Repository layout

Use a small, obvious deployment directory. Something along these lines is appropriate:

```text
infra/mirror/
├── deploy.sh
├── cloudflare.sh
├── remote-apply.sh
├── laputa-mirror.service
├── laputa-cloudflared.service
└── laputa-mirror.sysusers
```

Do not fragment this into dozens of helpers. Three shell scripts is already plenty; use fewer if that is cleaner.

There should be no abstract "deployment framework" hidden inside these scripts. They exist specifically to deploy this one mirror.

## `make deploy-mirror`

Make this the canonical interface.

It should build what is required and then invoke the deployer.

Conceptually:

```make
deploy-mirror: mirror-build-x86_64-musl mirror-frontend
	./infra/mirror/deploy.sh
```

Adjust dependencies/layout as appropriate.

Remove the old `.deb` deployment machinery if nothing else legitimately uses it:

- `mirror-deb`
- old `mirror-deploy`
- Debian package staging
- generated maintainer scripts
- `DEB_*` deployment variables
- obsolete README instructions

A compatibility alias from `mirror-deploy` to `deploy-mirror` is acceptable if useful, but `deploy-mirror` should be the canonical documented target.

The initial production cutover also needs a one-time fresh start of the R2
contents. Keep it behind an explicit `deploy-mirror-fresh` target so routine
deployments never delete package objects. That path must wait until the new
public route is healthy, stop the mirror to prevent writes during Cloudflare's
asynchronous empty-bucket job, verify the bucket is empty, restart and recheck
the mirror, and only then retire the old tunnel. Keep the bucket itself.

## Release artifact

Do not package the mirror as a `.deb`.

Construct a minimal release containing:

```text
laputa-mirror
static/
```

Do not force an application refactor merely to embed static assets into the Rust executable. The existing layout is already simple.

Give each deployment a unique, path-safe release ID, such as a UTC timestamp
and process ID. The ID only distinguishes release directories; it does not
claim to identify or verify the artifact contents.

## Preflight first, mutate second

`make deploy-mirror` must perform a complete preflight before making meaningful changes.

Fail early and give a concise, actionable error.

Local checks should cover at least:

- repository/build prerequisites already needed by the mirror;
- `ssh`;
- `tar`;
- `curl`;
- `jq`;
- Cloudflare `cf`;
- required Cloudflare authentication;
- required R2 credentials;
- required deployment configuration;
- ability to build the mirror.

Remote checks should cover at least:

- SSH connectivity;
- Linux;
- expected CPU architecture;
- systemd;
- `systemctl`;
- `systemd-sysusers`;
- `tar`;
- `install`;
- `cmp`;
- `readlink`;
- `curl`;
- `flock`;
- `cloudflared`;
- enough privilege to deploy.

Support either:

```text
root over SSH
```

or:

```text
normal user + passwordless sudo
```

Do not design an interactive sudo workflow.

For a non-root user verify:

```sh
sudo -n true
```

before starting.

Never disable SSH host-key checking or otherwise weaken SSH safety.

Do not silently install a pile of operating-system packages. If a host prerequisite is missing, fail with an exact explanation of what is missing. The point of `deploy-mirror` is convergence after preflight succeeds, not becoming another configuration-management system.

A separate:

```sh
make preflight-mirror
```

or:

```sh
./infra/mirror/deploy.sh --preflight
```

would be useful if it falls out naturally, but `make deploy-mirror` must always run the same preflight itself.

## Configuration

Keep sensible defaults for this repository, while allowing overrides through environment variables.

Current production defaults can remain approximately:

```text
DEPLOY_HOST=oracle
MIRROR_HOSTNAME=laputa.17166969.xyz
MIRROR_R2_BUCKET=laputa-mirror
MIRROR_CF_TUNNEL=laputa-mirror
MIRROR_LISTEN_ADDR=127.0.0.1:3000
```

Derive where sensible:

```text
RP_ID=$MIRROR_HOSTNAME
RP_ORIGIN=https://$MIRROR_HOSTNAME
S3_ENDPOINT=https://$CF_ACCOUNT_ID.r2.cloudflarestorage.com
S3_REGION=auto
DB_PATH=/var/lib/laputa-mirror/auth.db
UPLOAD_DIR=/var/lib/laputa-mirror/uploads
```

Do not invent configuration knobs without a concrete need.

Rely on `~/.ssh/config` for unusual SSH settings instead of reproducing OpenSSH configuration in deployment environment variables.

Support an optional user-owned shell environment file outside the repository if this materially improves ergonomics, e.g.:

```text
MIRROR_DEPLOY_ENV=$HOME/.config/laputa/mirror-deploy.env
```

If you do this, clearly document that it is a shell fragment sourced by the deployment script.

Secrets must never be committed to the repository.

## Secrets

At minimum the deployment needs:

```text
CLOUDFLARE_API_TOKEN
CF_ACCOUNT_ID

S3_ACCESS_KEY_ID
S3_SECRET_ACCESS_KEY

MIRROR_ALLOWED_USERS
```

The Cloudflare API token is a **local deployment credential only** and must never be copied to the server.

Treat the S3 key ID and secret as server credentials.

Do not put secret values:

- on command lines;
- in logs;
- in generated systemd `Environment=` entries;
- into world-readable files;
- into release directories.

Add clean `_FILE` support to `laputa-mirror` for the R2 credentials.

For example:

```text
S3_ACCESS_KEY_ID_FILE
S3_SECRET_ACCESS_KEY_FILE
```

Implement this generically enough to be clean but do not refactor the whole configuration system.

Semantics should be straightforward:

- if the normal environment variable is present, use it;
- otherwise if `<NAME>_FILE` is present, read that file;
- otherwise required-value handling remains an error.

Trim only the expected terminal newline from credential files; don't unexpectedly mangle credentials.

Add tests for this behavior.

On systemd, use credentials rather than directly placing the secrets in the service environment.

A good arrangement is:

```ini
LoadCredential=s3-access-key-id:/etc/laputa-mirror/credentials/s3-access-key-id
LoadCredential=s3-secret-access-key:/etc/laputa-mirror/credentials/s3-secret-access-key

Environment=S3_ACCESS_KEY_ID_FILE=%d/s3-access-key-id
Environment=S3_SECRET_ACCESS_KEY_FILE=%d/s3-secret-access-key
```

Use the appropriate current systemd credential-directory specifier after verifying it.

The source credential files under `/etc` should be `root:root` and mode `0600`, with their containing directory appropriately restricted.

Do not introduce encrypted systemd credentials, TPM dependencies, Vault, SOPS, etc. Plain root-only files feeding `LoadCredential=` are sufficient here.

## systemd service

Replace the package-installed unit with a repository-owned unit deployed directly under `/etc/systemd/system`.

The application unit should conceptually be:

```ini
[Unit]
Description=Laputa Package Mirror
Wants=network-online.target
After=network-online.target

[Service]
Type=exec
User=laputa-mirror
Group=laputa-mirror

WorkingDirectory=/opt/laputa-mirror/current
ExecStart=/opt/laputa-mirror/current/laputa-mirror

EnvironmentFile=/etc/laputa-mirror/env

StateDirectory=laputa-mirror
StateDirectoryMode=0700

Restart=on-failure
RestartSec=2s

NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
UMask=0077

[Install]
WantedBy=multi-user.target
```

Do not blindly copy this if any directive is incompatible with the actual application. Validate it and use the strongest simple hardening that does not make the service brittle.

Prefer `Type=exec` over `Type=simple` if supported by the host baseline.

Keep the state directory writable while the rest of the filesystem view is appropriately restricted.

Use `systemd-sysusers` for the service account rather than imperative `useradd`.

## cloudflared runtime

The tunnel must be **remotely managed** by Cloudflare.

Do not leave a local Cloudflare tunnel YAML configuration on the host.

The host only needs:

- `cloudflared`;
- the tunnel token;
- a systemd service.

Use `cloudflared` solely as the runtime data-plane daemon.

Something approximately like:

```ini
[Unit]
Description=Laputa Cloudflare Tunnel
Wants=network-online.target
After=network-online.target laputa-mirror.service

[Service]
Type=exec

LoadCredential=tunnel-token:/etc/laputa-cloudflared/token

ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token-file %d/tunnel-token

Restart=on-failure
RestartSec=2s

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
```

Again, verify the actual `cloudflared` path and currently supported `--token-file` syntax rather than cargo-culting this snippet.

Do not run Cloudflare's generic package-installed `cloudflared.service` if it conflicts with this. Own one explicitly named `laputa-cloudflared.service`.

## Cloudflare reconciliation

Use Cloudflare's new `cf` CLI.

Do not use Wrangler.

Do not use Terraform/OpenTofu.

Do not use `cloudflared` itself to create/manage the Cloudflare control-plane resources.

The deployment should reconcile exactly the small set of Cloudflare resources Laputa needs:

1. R2 bucket:
   ```text
   laputa-mirror
   ```

2. remotely-managed Cloudflare Tunnel:
   ```text
   laputa-mirror
   ```

3. tunnel ingress:
   ```text
   laputa.17166969.xyz
       -> http://127.0.0.1:3000
   ```

   with the appropriate final 404 catch-all.

4. DNS for the mirror hostname pointing at that tunnel.

5. retrieve the tunnel token needed by the host.

`cf` is still a young CLI and its generated command names can change. Do not guess based on Wrangler or old Cloudflare examples.

Inspect the current installed `cf` CLI, `cf --help`, its discovery/search functionality, and current Cloudflare API semantics and implement against the actual current interface.

Centralize the exact `cf` invocations in `cloudflare.sh` rather than scattering them throughout deployment code.

Use machine-readable JSON output and `jq`. Do not parse human-formatted output with `sed`/`awk`.

The reconciler must always:

```text
read actual state
compare with desired state
mutate only when different
```

No local Terraform-style state file.

Cloudflare itself is the source of truth.

If an object already exists in the desired state, print an unchanged indication and do nothing.

If there are ambiguous or conflicting resources, fail rather than guessing. Examples:

- multiple tunnels with the same expected name;
- hostname occupied by an incompatible DNS record;
- unexpected account/zone;
- an object whose identity cannot safely be established.

Never destroy unrelated Cloudflare resources.

Determine and document the minimum Cloudflare API token permissions required by the operations actually used.

If `cf` cannot currently perform one genuinely necessary operation, investigate the current public API. A very small direct HTTPS call is preferable to adding Terraform, but use `cf` wherever it provides the operation.

## Host-side convergence

The remote application script should reconcile the desired host state.

Own only specific Laputa files/directories. Do not enumerate and "clean" unrelated `/etc` state.

Ensure:

```text
/opt/laputa-mirror
/opt/laputa-mirror/releases
/etc/laputa-mirror
/etc/laputa-mirror/credentials
/etc/laputa-cloudflared
```

with appropriate modes/ownership.

Install the sysusers declaration and run `systemd-sysusers`.

Install configuration files using a compare-before-replace pattern:

```text
if content differs:
    install replacement
    mark relevant service dirty
else:
    no-op
```

Do the same for secret files using `cmp -s`, without ever printing their contents.

Track independently whether:

- systemd daemon reload is needed;
- `laputa-mirror` restart is needed;
- `laputa-cloudflared` restart is needed.

A second identical deployment should not restart healthy services for no reason.

But desired state includes services being enabled and running. If a service is stopped, `make deploy-mirror` should bring it back.

## Upload transport

Use OpenSSH.

There is no objection to `ssh`, `scp`, or streaming tar over SSH.

A particularly clean implementation would be:

1. create a secure local temporary bundle;
2. include the release and non-secret deployment files;
3. include credentials as mode-0600 temporary files;
4. stream the bundle using `tar | ssh`;
5. extract it into a remote user-owned `mktemp -d`;
6. invoke the root-side POSIX shell reconciler;
7. securely remove the temporary directory.

Do not pass credentials as command-line arguments.

Do not interpolate secrets into remotely executed shell strings.

Clean local and remote temporary files using traps.

## Deployment lock

Two simultaneous deployments must not race.

Use a simple remote deployment lock.

`flock` is fine and already part of the expected Debian baseline.

Do not build a locking subsystem.

## Release installation

Never modify an installed release directory in place.

For a new release:

```text
upload/unpack into temporary directory
        ↓
check the binary and static directory are present and contain no symlinks
        ↓
set final ownership/modes
        ↓
rename into:
    /opt/laputa-mirror/releases/<release-id>
```

The final rename should be on the same filesystem and atomic.

If that exact release already exists and validates, reuse it rather than uploading/reinstalling it.

Then activation is solely the `current` symlink.

Use a safe atomic replacement pattern such as:

```text
create current.new
rename current.new over current
```

Use Linux filesystem semantics deliberately; the remote host is Linux even though the controlling script is POSIX shell.

Before activation, record the previous `current` target.

Never follow uncontrolled symlinks when recursively deleting or changing ownership. Be very defensive around every path passed to `rm -rf`.

## Health check and rollback

This is important.

Changing `current` is not success.

After activation/restart:

1. verify `laputa-mirror.service` is active;
2. repeatedly check:
   ```text
   http://127.0.0.1:3000/health
   ```
   from the host;
3. use a small bounded retry window;
4. only declare the host deployment successful after the health endpoint succeeds.

If activation or local health fails:

```text
new release
    ↓ failed
restore previous current symlink
restore any host config involved in the transaction if necessary
daemon-reload if required
restart previous service
verify old health
exit nonzero
```

The rollback behavior should also work when systemd unit/config changes were part of the failed deploy. Do not implement "rollback" that switches the binary back while leaving a broken new unit installed.

A straightforward temporary backup of the small number of managed host files is fine.

On a first-ever deployment with no previous release, stop the failed service and leave the system in an obvious failed/unactivated state.

Do not delete the failed release immediately; it is useful for diagnosis and can be GC'd later.

Cloudflare control-plane reconciliation is not required to be part of this application rollback transaction. It is independently idempotent.

After local health succeeds:

- ensure/restart `laputa-cloudflared` if needed;
- verify it is active;
- check:
  ```text
  https://$MIRROR_HOSTNAME/health
  ```
  from the deployment machine with a bounded retry.

If the local application is healthy but the public check fails, do **not** roll back a known-good application binary just because DNS/Tunnel connectivity failed. Fail the deployment with useful Cloudflare/systemd diagnostics.

## Release garbage collection

After a completely successful deployment, retain a small number of recent immutable releases, e.g. 3.

Never delete:

- the current release;
- the immediately previous release during the deployment;
- anything outside the exact release directory.

GC should happen only after success.

Be conservative.

## Idempotency requirements

This is a convergence command, not a blind script.

Running:

```sh
make deploy-mirror
make deploy-mirror
```

with no intervening changes should result approximately in:

```text
release: unchanged
systemd units: unchanged
configuration: unchanged
credentials: unchanged
R2 bucket: unchanged
Cloudflare tunnel: unchanged
tunnel ingress: unchanged
DNS: unchanged
laputa-mirror: already active and healthy
cloudflared: already active
public health: healthy
```

No unnecessary:

- release upload;
- service restart;
- daemon reload;
- Cloudflare mutation;
- DNS update.

If someone manually stops a desired service, the next run should repair that state.

If someone manually changes a managed config file, the next run should restore the repository-declared version.

That is the sense in which this deployment is declarative.

## UX

Make output terse but useful.

Something roughly like:

```text
==> Preflight
ok  local tooling
ok  ssh oracle
ok  remote systemd/sudo
ok  Cloudflare credentials

==> Build
ok  laputa-mirror
ok  frontend
    release 777bf45-a13c90d4c872

==> Cloudflare
=   R2 bucket laputa-mirror
=   tunnel laputa-mirror
~   tunnel ingress
=   DNS laputa.17166969.xyz

==> Host
=   sysusers
=   systemd units
~   R2 credentials
+   release 777bf45-a13c90d4c872
->  activated

==> Verify
ok  laputa-mirror.service
ok  http://127.0.0.1:3000/health
ok  laputa-cloudflared.service
ok  https://laputa.17166969.xyz/health
```

Use simple ASCII unless there is a compelling reason otherwise.

Errors should tell me the failed invariant and the next useful diagnostic.

On systemd failure, showing a small bounded tail such as:

```sh
journalctl -u laputa-mirror.service -n 50 --no-pager
```

is appropriate.

Never dump environment variables or secrets while debugging.

An optional dry-run/plan mode would be valuable if it can be implemented cleanly:

```sh
DEPLOY_DRY_RUN=1 make deploy-mirror
```

It should still perform reads/preflight and show intended changes, but not mutate anything.

Do not contort the code to support dry-run if it materially degrades simplicity.

## POSIX shell quality

Treat the shell code as production code.

Requirements:

- `set -eu`;
- quote expansions unless intentional splitting is explicitly required;
- no parsing `ls` where avoidable;
- predictable `IFS`;
- `mktemp` for temporary state;
- traps for cleanup;
- no secret leakage under `set -x`;
- no `eval`;
- no remote shell command assembled from untrusted arbitrary strings;
- reject invalid values rather than trying to escape impossible inputs;
- functions with narrow jobs;
- centralized logging/error helpers;
- use `printf`, not portability-sensitive `echo` behavior;
- run ShellCheck in POSIX mode;
- avoid clever shell.

Inputs such as hostnames, bucket names, tunnel names and release IDs should be validated against appropriately narrow character sets before they are interpolated into paths or commands.

## Testing

This deployment path needs meaningful tests despite being shell.

Do not introduce a huge test harness.

At minimum, make the shell logic easy enough to test with fake commands on `PATH` or another similarly small mechanism.

Cover the important invariants:

1. missing required secret fails in preflight before mutation;
2. missing remote prerequisite produces an actionable failure;
3. reapplying an already installed release produces no host restart;
4. identical Cloudflare state produces no mutation;
5. new release activates atomically;
6. failed health check restores the old `current`;
7. failed health check restores relevant old systemd/config state;
8. credential contents never appear in normal output;
9. conflicting Cloudflare resources cause failure instead of destructive guessing;
10. malformed release ID fails before activation.

Also run the real existing mirror tests.

Validate the final shell under a genuinely POSIX shell, not merely Bash invoked as `sh`.

## Documentation

Rewrite `mirror/README.md` deployment documentation around the new workflow.

It should no longer be a long manual procedure involving:

```text
build .deb
scp
dpkg
edit env file
cloudflared tunnel login
cloudflared tunnel create
copy tunnel JSON
write tunnel YAML
systemctl ...
```

Instead document:

### One-time prerequisites

- Debian/Ubuntu-style systemd host;
- SSH access;
- root or passwordless sudo;
- `cloudflared` installed on the host;
- local build requirements;
- local `cf`, `jq`, SSH tooling;
- Cloudflare API token with the exact required permissions;
- R2 S3 credentials.

### Configure secrets

Show the recommended environment/environment-file shape without real values.

### Deploy

```sh
make deploy-mirror
```

### Inspect

```sh
ssh oracle systemctl status laputa-mirror.service
ssh oracle systemctl status laputa-cloudflared.service
ssh oracle journalctl -u laputa-mirror.service
readlink /opt/laputa-mirror/current
```

### Rollback manually

Document the simple underlying primitive:

```text
point current at an older releases/<id>
restart laputa-mirror
check /health
```

The system should be understandable without knowing the deployment script internals.

## Non-goals

Do not:

- make this multi-host;
- invent roles/inventories;
- create a generic provisioning library;
- manage the whole operating system;
- install OS security updates;
- manage SSH itself;
- manage arbitrary users;
- implement a secret manager;
- replace systemd;
- create an OCI image;
- introduce a registry;
- automate R2 access-key lifecycle unless the current `cf`/Cloudflare API makes that genuinely trivial and safe;
- rewrite unrelated mirror code;
- change package publication semantics;
- expose port 3000 publicly.

Keep the scope relentlessly centered on deploying this one static service correctly.

## Final verification

Before declaring the work finished, test from a clean-enough state and verify:

```sh
make mirror-test
make deploy-mirror
make deploy-mirror
```

The first deployment should converge the host.

The second should be a real no-op apart from preflight/read checks and health verification.

Verify:

```text
https://laputa.17166969.xyz/health
```

works through the remotely managed Cloudflare Tunnel.

Verify that:

- there is no production Docker daemon dependency;
- no `.deb` is involved;
- no Wrangler is involved;
- no local Cloudflare tunnel YAML/credential JSON is needed;
- R2 secrets are absent from process arguments and ordinary service environment;
- `current` is the only mutable application activation pointer;
- a deliberately broken candidate release is automatically rolled back;
- the deployment remains understandable by reading the shell scripts, systemd units, and directory tree.

Prefer deleting obsolete deployment code over leaving two competing ways to deploy.

The desired result is not a miniature Ansible. It is a very small, high-confidence release transaction built from ordinary Unix primitives.
