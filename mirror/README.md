# Laputa Mirror

`laputa-mirror` serves the Laputa PM repository format from an S3-compatible
bucket and exposes authenticated `PUT` publishing for:

- `index.json`
- `snapshot.json`, `snapshot.sig` and `indexes/<index-sha256>.json`
- `packages/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>.tar.gz`
- `metadata/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json`
- `proofs/<arch>/<name>/<name>-<ver>-<rel>-<artifact12>-<proof12>.json`
- `sources/<name>/<name>-<ver>-<rel>-<arch>-src.tar.bz2`

Package objects are content-addressed: `<artifact12>` and `<proof12>` are the
first twelve hex digits of the row's `artifact_key` and `proof_key`. A rebuild
under the same ver-rel uploads new objects and replaces only its `index.json`
row, which is the sole mutable pointer; PM uploads objects with
`If-None-Match: *`. An index row that names any content-addressed object must
name exactly the objects of its keys. `snapshot.json` and `snapshot.sig` are
the other mutable objects: the offline-signed snapshot metadata and its raw
Ed25519 signature. The mirror holds no verification key. It stores and serves
both byte for byte with `Cache-Control: no-store`, never redirects them to an
object cache, and refuses writes over 8192 bytes (metadata) or 256 bytes
(signature); clients authenticate the pair. `indexes/<index-sha256>.json` is
the immutable copy of the signed index bytes: the mirror refuses a body whose
SHA-256 differs from its name, a replacement of an existing object under
`If-None-Match: *`, and chunked assembly. Legacy object names remain readable, but
writes accept only content-addressed names. Source mirrors are
target-architecture-specific and their paths are derived from the package
index entry.

## HTTP admission limits

The server admits eight active connections and queues eight more. Additional
connections receive 503 and close. Request headers have 10 seconds to arrive;
the entire request body has 30 seconds. Bodies are limited to 128 MiB for
package, source, and upload-chunk PUTs; 10 MiB for index PUTs; and 64 KiB for
all other requests, including authentication and upload completion. Limits
apply to both Content-Length and streamed HTTP chunked bodies. Rejected bodies
receive 413, and body read timeouts receive 408. Protected writes are checked
before their body is read.

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

On the mirror host, using the same `DB_PATH` and `ALLOWED_USERS` as the
service, run the local operator tool from the mirror source directory:

```sh
cargo run --example enrollment -- list
cargo run --example enrollment -- issue USER
```

Review the listed credential and token IDs before reopening enrollment. The
issue command prints a secret once; deliver it privately to the named user. It
expires after 10 minutes, is valid for one first passkey, and is invalidated by
issuing another or running `cargo run --example enrollment -- revoke USER`.
The user enters it on `/auth` with the allowlisted username. Do not put it in a
URL or log. Existing credentials and tokens are retained.

For another passkey, enter the account username and sign in with an existing key, then register for the same
username within 10 minutes. Token creation also requires a WebAuthn sign-in in
the last 10 minutes; ordinary browser sessions last 30 days. Registration alone
is not a WebAuthn sign-in, so sign in before creating a named token. The first
registration may issue the initial CLI token, shown once.

If all keys are lost, an operator must review and explicitly remove the affected
credentials from the SQLite database before issuing a new authorization. Stop
the service, back up the database, and use SQLite with a bound username to
delete only rows in `credentials` for that user ID. Review and explicitly
revoke uncertain tokens separately; recovery does not revoke them automatically.
Restart the service and issue a new authorization. Protect database access as
publisher authority.

## Publish packages

`pm.xsh -- repo publish` is the only publisher. It uploads content-addressed
payload, metadata, and proof objects (large ones in chunks) and writes
`index.json` last. `pm.xsh -- repo publish-snapshot --from DIR` then publishes
an offline-signed snapshot binding that exact index (see [PM publication](../docs/PM.md#snapshot-authentication)). See [PM publication](../docs/PM.md#publication) and `make publish` for a
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

## Outbound HTTPS trust

Production outbound HTTPS (R2/S3 and JWKS) uses the host operating-system
trust store with no bundled roots; see the
[deployment guide](../docs/MIRROR-DEPLOYMENT.md#outbound-tls-trust) for the
host requirement, refresh behavior, and the exact TLS dependency closure.

## Frontend and passkey demo

`make mirror-frontend` installs pnpm with Node's npm at `PNPM_VERSION` (default
`12.18.0`), installs the locked frontend dependencies, and builds the static
assets used by the mirror.
`make mirror-demo` builds those assets and runs the in-memory demo server at
`http://localhost:3000`. It requires a host Rust toolchain. Register a passkey as
`demo` using the printed authorization, sign in, create a token, then use the printed `curl` commands to try an
unauthenticated request and an authorized publish. Demo data disappears when
the process exits.
