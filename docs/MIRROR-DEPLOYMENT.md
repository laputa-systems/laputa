# Mirror deployment

Deploy the mirror to Cloudflare R2 and a remotely managed Tunnel.
Leave `R2_PUBLIC_URL` unset to serve downloads through the mirror.

## Production architecture

```text
Laputa PM clients
  -> https://laputa.17166969.xyz
  -> Cloudflare Tunnel
  -> cloudflared on the server
  -> http://127.0.0.1:3000
  -> laputa-mirror
  -> Cloudflare R2 bucket: laputa-mirror
```

The server does not need inbound ports open. `cloudflared` makes outbound
connections to Cloudflare and forwards the public hostname to the local mirror.
The deployment installs immutable releases under `/opt/laputa-mirror/releases/`
and switches the `/opt/laputa-mirror/current` symlink to activate one. Database
and upload state stay under `/var/lib/laputa-mirror/`.

## One-time prerequisites

The deployment host must be an x86_64 Debian or Ubuntu style system with
systemd 247 or newer, SSH access as root or a user with passwordless sudo, and
`cloudflared` installed at `/usr/bin/cloudflared`. The deployment checks for
`cloudflared tunnel run --token-file` support. It does not install host
packages or configure SSH.

The build machine needs Docker with Buildx, Deno, Node.js, Make, OpenSSH,
`curl`, `jq`, and the Cloudflare `cf` CLI. `make deploy-mirror` checks these
and the remote prerequisites before building.

Authenticate the Cloudflare CLI with `cf auth login`, or provide a scoped
`CLOUDFLARE_API_TOKEN` in the deployment environment file below. The account
must be available to that `cf` profile. When more than one account is
available, set `CF_ACCOUNT_ID` explicitly.

The Cloudflare API token needs these account and zone permissions for the
read-before-write reconciliation, tunnel setup, and legacy tunnel cleanup:

- Account: `Workers R2 Storage Read` and `Workers R2 Storage Write`.
- Account: `Cloudflare Tunnel Read` and `Cloudflare Tunnel Write` (the current
  API also accepts the equivalent `Cloudflare One Connector: cloudflared`
  read/write permissions).
- The mirror zone: `Zone Read`, `DNS Read`, and `DNS Write`.

Cloudflare's [API token permission reference](https://developers.cloudflare.com/fundamentals/api/reference/permissions/)
lists the current names. The [R2 bucket API](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/methods/create/),
[Tunnel API](https://developers.cloudflare.com/api/resources/zero_trust/subresources/tunnels/subresources/cloudflared/methods/create/),
and [DNS record API](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/)
describe the operations used by the reconciler.

Create an R2 S3 API token with object read/write access to the `laputa-mirror`
bucket. This is separate from the Cloudflare API token. The deployment needs
the R2 access key ID, secret, and the usernames allowed to register passkeys.
It does not create or rotate R2 access keys.

## Configure deployment secrets

Create `$HOME/.config/laputa/mirror-deploy.env` with mode `0600`. It is a
POSIX shell fragment sourced by the deployment script, so quote values using
ordinary shell syntax. Keep it outside the repository.

```sh
mkdir -p "$HOME/.config/laputa"
chmod 700 "$HOME/.config/laputa"
${EDITOR:-vi} "$HOME/.config/laputa/mirror-deploy.env"
chmod 600 "$HOME/.config/laputa/mirror-deploy.env"
```

Example contents:

```sh
# Optional when cf is already authenticated with a profile.
CLOUDFLARE_API_TOKEN='replace-with-a-scoped-token'
CF_ACCOUNT_ID='replace-with-account-id'

# Use direct values or *_FILE paths for the R2 S3 credentials.
S3_ACCESS_KEY_ID_FILE="$HOME/.config/laputa/r2-access-key-id"
S3_SECRET_ACCESS_KEY_FILE="$HOME/.config/laputa/r2-secret-access-key"
MIRROR_ALLOWED_USERS='josh'

# Optional SSH alias and application JWT settings.
DEPLOY_HOST='ubuntu@oracle'
# JWT_JWKS_URL='https://token.actions.githubusercontent.com/.well-known/jwks'
# JWT_ISSUER='https://token.actions.githubusercontent.com'
# JWT_AUDIENCE='laputa-mirror'
# JWT_SUBJECT_PATTERN='repo:josh/*'
```

Protect credential files with mode `0600`. The mirror reads one terminal LF
from each S3 credential file and otherwise preserves its contents. Direct
`S3_ACCESS_KEY_ID` or `S3_SECRET_ACCESS_KEY` environment values take precedence
over the corresponding `_FILE` setting.

Defaults are `DEPLOY_HOST=ubuntu@oracle`,
`MIRROR_HOSTNAME=laputa.17166969.xyz`, `MIRROR_R2_BUCKET=laputa-mirror`,
`MIRROR_CF_TUNNEL=laputa-mirror`, and `MIRROR_LISTEN_ADDR=127.0.0.1:3000`.
Override them in this file when needed. For a different environment file, set
`MIRROR_DEPLOY_ENV=/path/to/file`.

## Deploy

Run the read-only checks independently if desired, then deploy:

```sh
make preflight-mirror
make deploy-mirror
```

`deploy-mirror` always runs preflight, builds the x86_64 MUSL server and
frontend, then converges Cloudflare and the host. The first deployment creates
the R2 bucket or remotely managed tunnel only when missing. It starts the new
tunnel and checks local health before changing DNS. It checks public health
before retiring the old mirror tunnel and any installed legacy `laputa-mirror`
Debian package. A generic `cloudflared.service` is removed only when its local
configuration identifies that mirror tunnel and contains no other hostnames.
It never prints credential contents.

Routine deployments preserve R2 objects. For a deliberate one-time reset, use
`make deploy-mirror-fresh`. After the new public route is healthy, this stops
the mirror, empties the bucket's objects, waits for Cloudflare's job to finish,
verifies the bucket is empty, then restarts and rechecks the mirror before
retiring the old tunnel. The bucket itself remains. The mirror is unavailable
while the emptying job runs, so reserve this target for a planned fresh start.

Each deployment gets a unique timestamped release directory. The deployment
switches `current` atomically, rolls back the application and managed host
configuration after a failed local health check, and retains the current,
previous, and one additional release after a successful deployment.

To deploy to another host, use an SSH host or `user@host` and rely on
`~/.ssh/config` for connection settings:

```sh
DEPLOY_HOST='ubuntu@another-host' make deploy-mirror
```

## Inspect

```sh
ssh ubuntu@oracle systemctl status laputa-mirror.service
ssh ubuntu@oracle systemctl status laputa-cloudflared.service
ssh ubuntu@oracle journalctl -u laputa-mirror.service
ssh ubuntu@oracle readlink /opt/laputa-mirror/current
curl -fsS https://laputa.17166969.xyz/health
```

The mirror listens only on `127.0.0.1:3000`. R2 credentials are root-owned
files under `/etc/laputa-mirror/credentials/`, loaded by systemd as service
credentials. The Cloudflare runner token is stored at
`/etc/laputa-cloudflared/token` and is also loaded through a systemd credential.
Neither appears in the service environment or process arguments.

## Roll back manually

List releases and choose an older ID, then atomically point `current` at it and
restart the mirror:

```sh
ssh ubuntu@oracle 'sudo ln -s releases/OLDER_RELEASE /opt/laputa-mirror/current.rollback'
ssh ubuntu@oracle 'sudo mv -Tf /opt/laputa-mirror/current.rollback /opt/laputa-mirror/current'
ssh ubuntu@oracle 'sudo systemctl restart laputa-mirror.service'
ssh ubuntu@oracle 'curl -fsS http://127.0.0.1:3000/health'
```

