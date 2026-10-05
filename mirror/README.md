# Laputa Mirror

`laputa-mirror` serves the Laputa PM repository format from an S3-compatible
bucket and exposes authenticated `PUT` publishing for:

- `index.json`
- `packages/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>.tar.gz`
- `metadata/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json`
- `proofs/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json`
- `sources/<name>/<name>-<ver>-<rel>-<arch>-src.tar.bz2`

Package objects are content-addressed: `<artifact12>` and `<proof12>` are the
first twelve hex digits of the row's `artifact_key` and `proof_key`. A rebuild
under the same ver-rel uploads new objects and replaces only its `index.json`
row, which is the sole mutable pointer; PM uploads objects with
`If-None-Match: *`. An index row that names any content-addressed object must
name exactly the objects of its keys. Legacy object names remain readable, but
writes accept only content-addressed names. Source mirrors are
target-architecture-specific and their paths are derived from the package
index entry.

This guide deploys `https://laputa.17166969.xyz/` with Cloudflare R2 and a
remotely managed Cloudflare Tunnel. Leave `R2_PUBLIC_URL` unset so package
downloads are served through `laputa-mirror` instead of redirecting clients to
a public R2 URL.

## Local mode

For local development and offline bootstraps, run the mirror against a
directory instead of S3, with no auth:

```sh
laputa-mirror --local DATA_DIR [--listen 127.0.0.1:PORT] [--sources SOURCE_CACHE_DIR]
make mirror
```

- Objects live at `DATA_DIR/<key>`. Writes land in a temporary file beside the
  object and are renamed into place, so readers never see a partial object.
- Reads and writes need no token. `PUT` objects, `index.json`, and chunked
  uploads work unauthenticated.
- `GET` streams objects from disk with `Content-Length`; nothing redirects.
- `--sources DIR` serves `DIR/sha256/<hash>` read-only at
  `/sources/sha256/<hash>`, where `<hash>` is 64 lowercase hex digits.
- `--listen` defaults to `127.0.0.1:3000` and must be a loopback IP address.
  Anyone who can reach that port can publish.
- `/auth` routes return 404. No database, WebAuthn, JWT, or S3 settings are
  read; production environment variables are ignored.

Running `laputa-mirror` with no arguments is production mode.

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

## Create the first publisher token

Open `https://laputa.17166969.xyz/auth` and register a passkey using a username
from `MIRROR_ALLOWED_USERS`. Then open
`https://laputa.17166969.xyz/auth/settings`, create a named token, and store it
when it is shown. Tokens are displayed only at creation time.

## Publish packages

`pm.xsh -- repo publish` is the only publisher. It uploads content-addressed
payload, metadata, and proof objects (large ones in chunks) and writes
`index.json` last. See `docs/PM.md` under "Publication" and `make publish` for a
local mirror. The mirror service is the only component that writes to R2.

## Configure PM clients

`XSH_PM_REPO` is the only repository setting; when it is empty, PM plans
offline. Publishing to the production mirror needs a token from
`/auth/settings`:

```sh
export XSH_PM_REPO=https://laputa.17166969.xyz
export LAPUTA_TOKEN=<token_from_settings>
```

The local mirror (`make mirror`) needs no token.
