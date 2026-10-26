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
For host setup, credentials, deployment, inspection, and rollback, use the
[deployment guide](../docs/MIRROR-DEPLOYMENT.md).

## Create the first publisher token

Open `https://laputa.17166969.xyz/auth` and register a passkey using a username
from `MIRROR_ALLOWED_USERS`. Then open
`https://laputa.17166969.xyz/auth/settings`, create a named token, and store it
when it is shown. Tokens are displayed only at creation time.

## Publish packages

`pm.xsh -- repo publish` is the only publisher. It uploads content-addressed
payload, metadata, and proof objects (large ones in chunks) and writes
`index.json` last. See [PM publication](../docs/PM.md#publication) and `make publish` for a
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

## Frontend and passkey demo

`make mirror-frontend` installs pnpm through Deno at `PNPM_VERSION` (default
`11.0.2`), installs the locked frontend dependencies, and builds the static
assets used by the mirror.
`make mirror-demo` builds those assets and runs the in-memory demo server at
`http://localhost:3000`. It requires a host Rust toolchain. Register a passkey as
`demo`, create a token, then use the printed `curl` commands to try an
unauthenticated request and an authorized publish. Demo data disappears when
the process exits.
