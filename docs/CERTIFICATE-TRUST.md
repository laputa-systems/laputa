# Certificate trust

## Layout

| Path | Owner | Content |
|---|---|---|
| `/etc/ssl/certs/ca-certificates.crt` | ca-certificates package (symlink) | Active root bundle → `../../../var/lib/laputa/trust/active/ca-certificates.crt` |
| `/etc/ssl/cert.pem` | ca-certificates package (symlink) | `certs/ca-certificates.crt` alias of the bundle |
| `/etc/laputa/trust-policy` | ca-certificates package (symlink) | Active distrust policy → `../../var/lib/laputa/trust/active/trust-policy` |
| `/etc/laputa/trust-update-key` | ca-certificates package, mode 0444 | Operator-provisioned 32-byte Ed25519 verification key |
| `/usr/share/laputa/trust/seed/` | ca-certificates package | Pinned bundle + policy seeds; install inputs, never network content |
| `/var/lib/laputa/trust/` | trust update (durable state) | `generations/<u64>/`, `active` symlink, `accepted`, `time-lower-bound`, `journal.json`, `update.lock`, `staging/` |
| `/usr/bin/trust` | laputa-pm package | `status`, `verify`, `update` entrypoint |

Laputa installs curl's 2026-10-20 Mozilla-derived bundle as the generation-1
seed. The pinned export contains 118 certificates and omits
`emSign ECC Root CA - G3`. The package proof checks the count, the removed
root, and every certificate's PEM encoding. The installer seeds the trust
store from these package seeds on every fresh install, so installed systems
verify trust from first boot; `trust update` bootstraps the same way when no
store exists, and refuses to bootstrap over a newer accepted generation.
Bootstrap verifies the seed generation and records it as accepted before
activating it, so an interrupted activation can resume from the verified seed.

Curl's PEM export does not preserve Mozilla root-specific Name Constraints.
Treat the bundle as a list of roots, not as Mozilla's complete trust program.
See [curl's CA extraction notes](https://curl.se/docs/caextract.html).

The distrust policy uses LF-terminated UTF-8: `laputa-trust-policy-v1`, a
canonical positive `u64` generation, then zero or more unique lowercase
64-digit `blocked-spki-sha256` values. Generation 1 blocks the six
compromised eMudhra TLS intermediate SPKI SHA-256 hashes in
[Mozilla Bugzilla 2083449](https://bugzilla.mozilla.org/show_bug.cgi?id=2083449).
PEM roots cannot express intermediate-key distrust. Keep broad alternative
roots so unrelated sites remain trusted.

## Releases

Signed releases are the only trust mutations. A release is exactly four
files: `metadata`, `metadata.sig` (raw 64-byte Ed25519), `ca-certificates.crt`
(≤ 4 MiB), `trust-policy` (≤ 1 MiB). Metadata is ≤ 4 KiB of LF-terminated
UTF-8 with exactly five ordered lines: `laputa-trust-release-v1`,
`generation`, `expires-at`, `root-bundle-sha256`, and `trust-policy-sha256`.
Releases expire within 90 days of signing. The policy generation must equal
the signed generation and advance the installed-policy snapshot. There is no
empty-state or test-key default; every check takes the provisioned key and
`now_epoch_seconds` from the host wall clock.

`trust.verify --from DIR` checks a release directory without changing state.
`trust update (--from DIR | --url URL)` verifies and atomically activates.
`--from` is the deterministic offline and emergency path: it needs no
networking and no working WebPKI trust store. `--url` fetches the same four
files over HTTPS; HTTPS is transport only and the detached signature over
pinned key material authorizes the release. Source files above their size
bounds, non-regular files, digest mismatches, stale generations, conflicting
bytes for the active generation, expired or over-long expiries, malformed
bundles or policies, and a clock behind the persisted lower bound all fail
closed without touching the store. Offline inputs are read through bounded
reads and re-statted after the read, so a file replaced or resized
concurrently is rejected instead of trusted.

## Activation

Activation is one linearization point: the atomic rename of the `active`
symlink onto `generations/<N>`. Around it:

- Staging writes the verified bytes to an owner-token directory under
  `staging/`, fsyncs every file, then commits by renaming the directory to
  `generations/<N>`. Committed generations are immutable; a conflicting
  commit with different bytes fails, a byte-identical one is adopted.
- The journal (`locked → staged → committed → activated → persisted`)
  records each step. Each phase replacement is an atomic rename, so recovery
  observes a complete phase, never a torn write from an interrupted
  transition; a torn journal from any cause fails closed for manual
  inspection. Interrupted runs recover deterministically on the next
  update, keyed by what survived: a journal naming a generation below the
  accepted high-water mark or below an already-active newer generation is
  rejected before any branch mutates the store; staged work with its
  directory intact is removed; a staged journal whose directory already
  renamed is adopted by verifying and flipping the committed generation,
  with expiry enforced for a candidate that never activated (an
  already-active generation still rolls forward without re-authorization);
  a committed candidate is re-verified with new-candidate rules (expiry
  enforced) before flipping; an already-flipped generation rolls forward
  with bookkeeping verification (signature and digests, no expiry — an
  expired but correctly activated generation is reconciled, never
  re-authorized, and new candidates still require fresh expiry). Every
  recovery step persists the accepted generation and the time lower bound
  before clearing the journal. Unreadable or unknown journals,
  active/journal disagreements, and staging/commitment collisions fail
  closed for manual inspection.
- Atomic visibility and power-loss durability are separate claims. The
  active-pointer flip is a single atomic rename: readers never observe a
  half-written pointer. Durability across power loss comes from fsync
  ordering — file data before directory entries, directory entries before
  the renames that publish them, and the store directory after the flip —
  so a crash replays to the last journaled step, never to torn state.
  Process kills alone do not prove the power-loss path; the journal
  phase tests inject each crash window deterministically.
- `accepted` is a high-water mark that never rolls back distrust: updates
  must advance it, and a store whose accepted generation is ahead of active
  refuses to proceed.
- The persisted time lower bound advances on every activation and rejects
  releases the local clock reads as expired relative to it.
- After the flip, activation re-reads the canonical paths until they agree
  with the activated digests, so `status` never reports a half-visible
  generation.

`trust.status` reports the active generation, bundle and policy digests,
key fingerprint, last activation, accepted generation, pending journal work,
staging debris, and freshness. Status performs no writes: it never creates,
removes, or renames anything under the store, so concurrent status queries
are safe and leave sentinel files untouched. Status validates instead of
assuming: canonical bundle and policy bytes must match the committed
generation, the accepted generation must not lead the active one, and a
generation without either a signed release or seed provenance is reported
as incomplete rather than healthy. Concurrent
updates serialize on `update.lock`; a second updater is refused, never
queued.

`trust.release.release_verify` is the single verification path: it checks
the same metadata, signature, expiry, generation, and digests, and validates
every root certificate. The retired PM-side `compose_signed_release` was
removed: it created regular-file overlays at paths the ca-certificates
package owns as symlinks, and nothing called it. Activation goes only
through the versioned store. Existing paths and symlink aliases are never
removed to prepare staging. The staging guarantees assume trusted parent
directories. See [filesystem authority limits](PM.md#filesystem-authority-limits).

Laputa removed `update-certdata`. That command downloaded a bundle over HTTPS
and replaced the live file without verifying a Laputa signature, checking
rollback or expiry, or coordinating process state.

## Key ceremony

Production trusts exactly one key: the raw 32-byte Ed25519 *public* key at
`/etc/laputa/trust-update-key`, installed by the ca-certificates package at
mode 0444. The key file is operator-provisioned and never in the repository
(it is git-ignored; package builds fail closed without it). Generate the
pair offline, keep the private half on the signing machine, and install
only the public half:

1. Offline, on the signing machine (never the build host):
   `openssl genpkey -algorithm ed25519 -out trust-signing.key`
2. Extract the raw 32-byte public key and install it as the provisioned file:
   `openssl pkey -in trust-signing.key -pubout -outform DER | tail -c 32 > packages/ca-certificates/files/trust-update-key`
3. Back up `trust-signing.key` offline. Sign each release's `metadata` with
   `openssl pkeyutl -sign -inkey trust-signing.key -rawin -in metadata -out metadata.sig`
   (exactly 64 bytes). Never commit the private key or move it to the build host.
4. After install, confirm `trust status` reports
   `verification key: present sha256:<hex>` matching
   `sha256sum packages/ca-certificates/files/trust-update-key`.
   Distribute that fingerprint out-of-band; verifiers compare releases against it.

Rotate only through an OS package update that ships a new key file and new
seeds together; releases themselves never carry keys and cannot rotate,
revoke, or recover one. Losing the signing key means building a new key,
shipping it in a package update, and re-issuing releases. There is no
in-band recovery. `tests/pm/trust_update.xsh` builds that package update
from the rotated key and the new seed bytes, then checks that `trust
update` accepts the release signed by the new key and rejects releases
signed by the superseded key.

## Recovery

- Reboot or power loss mid-update: run `trust update` again (or reboot the
  guest). Journal recovery rolls forward committed candidates, removes owned
  staging, and never restores older policy. `trust.status` pending work
  returns to `none`.
- `trust journal is unreadable; refusing automatic recovery`: inspect
  `active`, `accepted`, and the generation directories by hand, verify the
  active bytes with `trust verify --from`, then remove `journal.json` only
  once active state is confirmed good.
- `accepted generation is ahead of active generation`: the store was copied
  or restored inconsistently. Do not delete `accepted` to work around it;
  reconcile which generation is genuinely installed and re-apply it.
- `system clock reads behind the persisted time lower bound`: fix the clock
  (see R2 time discipline) and retry; the bound only moves forward.
- Emergency trust repair without networking or WebPKI: `trust update
  --from DIR` with a verified release directory.

## Consumers

Known TLS consumers and their cutover:

| Consumer | TLS state | Cutover after `trust update` |
|---|---|---|
| `tailscale` (Go daemon, xinit-supervised) | Reads system roots at startup | `xinit restart tailscale` |
| `uv` | Upstream binary caches TLS roots; no Laputa SPKI policy | Start a new process |
| `dropbear` (SSH daemon, xinit-supervised) | Host keys only; no TLS roots | None needed |
| `laputa-net` (`ifup`, oneshot) | No long-lived client | None needed |
| `mdevd`, `seatd`, `wpa_supplicant` | No TLS | None needed |
| Long-lived XSH network clients | Pool pins its trust snapshot; changes fail closed until the pool is recreated | Close and recreate the pool (`net.close_pool`, then `net.pool`); the service keeps the rest of its state |

`trust update` never restarts services itself, so a restart failure cannot
roll back an activation: the store stays at the new generation and the
operator retries the restart. `trust.status` reports the last activation
time to correlate running processes with trust generations.

XSH TLS clients enforce `/etc/laputa/trust-policy` for every transport
admission, including requests that use custom roots. An installed policy,
even an empty blocklist, forbids disabling certificate verification. Without
a policy, explicit insecure development requests remain available. Redirects
are new admissions and recheck the policy. A request admitted before an update
may finish, including work already queued by the transport, internal retries,
or TLS resumption. A job
submitted but not yet admitted must fail after the pinned root or policy
snapshot changes. Changed, removed, or malformed snapshots fail closed until
the client is recreated. New clients read the activated generation. To cut
over existing services promptly, restart them after updating (for example
with `xinit restart SERVICE`). Laputa has no trust daemon and no service
cutover layer; the operator restarts long-lived processes.

The `uv` 0.13.4 package downloads checksum-pinned upstream musl binaries.
It uses Laputa's system store through `/etc/uv/uv.toml` and depends on
`ca-certificates`. It carries no distribution verifier patch and does not
read `/etc/laputa/trust-policy`. Root omission is enforced, but a blocked
intermediate that reaches a retained root remains accepted. uv remains an
explicit gap in per-consumer intermediate distrust enforcement.

Source-built Tailscale 1.104.2 uses a package-scoped Go 1.27.3 overlay.
Fresh and resumed TLS handshakes reread the canonical policy and check the
provided and verified certificate paths. Once a process observes a policy,
later deletion fails closed. Malformed, unreadable, and dangling policy paths
also fail closed. Existing connections can continue after an update.
System roots remain cached until process restart.

Tailscale's custom control verifier first performs ordinary Go certificate
verification, retaining both system and extra roots. Other configurations
that disable verification are rejected when policy is installed. This prevents
a server from hiding a blocked issuer by sending an incomplete chain.
An explicitly trusted leaf remains a valid trust anchor.

Both packages depend on `ca-certificates`. Go's Linux verifier reads the
canonical bundle and certificate files in `/etc/ssl/certs`. Laputa installs
only the canonical bundle there. The `qemu-tinyland-ghostty` profile includes
`ca-certificates` directly. These changes retain the remaining root bundle.

### Per-consumer distrust enforcement

The XSH and Tailscale regressions run real TLS connections in disposable Docker
containers without modifying host trust. They check each cross-signed form
with its corresponding retained root. The uv characterization uses `cross-r1`:

| Chain with installed policy | XSH | `uv` | `tailscaled` |
|---|---|---|---|
| Unblocked control | Connects | Connects | Connects |
| Blocked intermediate under `cross-r1` | Rejects | Connects | Rejects |
| Blocked intermediate under `cross-r2` | Rejects | No SPKI enforcement | Rejects |

Export `XSH_HOST` and `XSHT` as described in [development](DEVELOPMENT.md).
Run the focused package fixtures with extracted package roots:

```sh
"$XSHT" test tests/pm/trust_xsh_policy.xsh
LAPUTA_TRUST_CONSUMER_ROOT="$UV_ROOT" "$XSHT" test tests/pm/trust_consumers.xsh
LAPUTA_TAILSCALE_ROOT="$TAILSCALE_ROOT" "$XSHT" test tests/pm/tailscale_policy.xsh
```

The uv characterization accepts the unblocked control and the blocked
intermediate under `cross-r1`, and rejects the chain rooted in omitted
`cross-r2`. The upstream binary is retained by explicit packaging policy.
Tailscale's package-local Go fixtures cover fresh and resumed handshakes,
policy deletion, custom control connections, and preservation of system and
extra roots. `tailscale_policy.xsh` replaces Tailscale's former blocked-chain
acceptance characterization with enforcement regressions.

## Evidence

- `tests/pm/trust_update.xsh`: cryptographic matrix (wrong signer, tampered
  metadata, expiry bounds, digest mismatches, malformed inputs, oversize
  bounds), stale/conflicting re-application, generation advance, lock
  serialization, existing-generation conflicts, time-bound enforcement and
  persistence, staged/committed/unknown journal recovery, stale-journal
  rejection with zero mutation, monotonic accepted persistence, expired
  staged-adoption refusal with already-activated roll-forward preserved,
  torn-journal refusal, and kill -9 at random points converging on re-run.
- `tests/pm/trust_update_cli.xsh`: entrypoint wiring, usage errors,
  `--url` convergence with `--from`, trickle-download kill with no store
  mutation, and killed-mid-transaction recovery.
- `tests/pm/trust_update_tls.xsh`: trusted-chain acceptance, untrusted-chain
  rejection, pinned-snapshot poison requiring client recreation, and an
  unblocked control pair — all against fixture PKI, never touching host
  trust.
- `tests/pm/trust_xsh_policy.xsh`: the shipped XSH binary in disposable
  Docker containers accepts both cross-signed fixture chains without the
  fixture policy, rejects both with it even when ordinary TLS verification
  is disabled, and accepts the unblocked control. It uses the local
  `debian:stable-slim` image and leaves host trust unchanged.
- `tests/pm/ca_certificates_recipe.xsh`: layout, seed, provisioned-key, and
  seeded-store proof checks.
- `tests/system/trust_guest.xsh`: real KVM guests boot from the host kernel
  with a staged initramfs and a dedicated ext4 store disk, then update
  `--from` baked-in release B, reboot, update `--url` from a host fixture
  TLS server at 10.0.2.2, reboot, and replay generation 3; a second test
  SIGKILLs the guest mid-download and requires forward-only recovery to
  generation 3; a third test crafts a stale generation-1 committed journal on
  the booted generation-2 store and requires refusal with the store
  untouched. Serial markers carry the exact bundle and policy digests,
  which the host recomputes from fixtures.
- `packages/ca-certificates/proof.xsh`: layout, pinned roots, blocked SPKIs,
  provisioned key format, and an actually seeded store.
