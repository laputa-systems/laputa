# Certificate trust

Laputa installs the Mozilla-derived PEM bundle at `/etc/ssl/certs/ca-certificates.crt` and retains `/etc/ssl/cert.pem` as the conventional compatibility path. The package pins curl's 2026-10-20 export, containing 118 certificates. That export omits `emSign ECC Root CA - G3`; the package proof checks its certificate count and the root's absence. Curl notes that its PEM conversion does not preserve Mozilla root-specific Name Constraints, so this bundle is a root list rather than a complete browser trust program.

The bundle now changes only through a Laputa package and a composed system generation. The old `update-certdata` command downloaded over HTTPS and replaced the live bundle without verifying a distribution signature, enforcing rollback or expiry, or coordinating process state; it has been removed. Laputa does not yet publish signed emergency distrust metadata. Package artifact verification protects the package contents according to the package repository's existing trust model; it is not a separate Laputa trust-policy signature.

The `uv` package is 0.13.4. It uses the Laputa system store through `/etc/uv/uv.toml` and depends on `ca-certificates`; its upstream release updates bundled Mozilla roots to `webpki-root-certs` 1.0.10. Its pinned Cargo.lock still uses `rustls-webpki` 0.103.14, below the 0.103.16 release with compromised-SPKI rejection. The system-root setting removes the G3 anchor but does not establish rejection of cross-signed chains. Tailscale is 1.104.2, built with Go 1.27.3, and depends on the system CA package. Go's Linux verifier reads both the canonical bundle and certificate files in `/etc/ssl/certs`; Laputa currently installs only the canonical bundle there. The `qemu-dwl-foot` profile includes `ca-certificates` directly.

Deno remains at 2.9.7. Laputa sets `DENO_TLS_CA_STORE=system` for login-shell applications and declares a runtime dependency on `ca-certificates`. As of 2026-10-21, Deno's SPKI distrust fix is merged to its main branch but is not in a release. Using the system roots removes the retired root anchor, but it does not reject cross-signed chains containing a compromised intermediate key. Do not treat the Deno setting as an incident-complete mitigation.

The XSH networking verifier still needs policy integration. It currently reads the selected CA bundle and certificate directories, and caches its verifier after first TLS use. A Laputa policy file cannot enforce intermediate-SPKI distrust until XSH's existing verifier accepts that policy and applies it to every certificate in the validated chain, including when callers select custom roots. The XSH host boundary needed by the updater is a reusable Ed25519 verifier over exact message bytes with a raw 32-byte public key and raw 64-byte detached signature, returning `Result[Bool, Error]`: `false` means a correctly sized invalid signature, while malformed lengths and provider failures return errors. The updater must verify the downloaded metadata bytes before parsing sequence, expiry, or digests. It also needs a Laputa production public key provisioned as a trust anchor. No test key may be shipped as that anchor.

The signed update design should publish a versioned release containing a monotonic sequence, expiry, root-bundle digest, and distrust-policy digest. The updater must verify the detached signature before parsing policy metadata, validate both payloads, reject expired or rolled-back releases, and stage/publish through immutable package-generation semantics. If a live policy update is introduced, it must use the existing `xinit restart SERVICE` or `xinit reload SERVICE` operation for affected services after atomic publication; there is no trust daemon. Until that path and its key provisioning exist, update roots by publishing a new package generation and booting it.

Upstream references:

- [curl's Mozilla CA extraction and revision history](https://curl.se/docs/caextract.html)
- [Mozilla's eMudhra incident report and affected TLS intermediate SPKI hashes](https://bugzilla.mozilla.org/show_bug.cgi?id=2083449)
- [uv 0.13.4 changelog](https://github.com/astral-sh/uv/blob/0.13.4/CHANGELOG.md)
- [uv 0.13.4 Cargo.lock](https://github.com/astral-sh/uv/blob/0.13.4/Cargo.lock)
- [rustls-webpki advisory RUSTSEC-2026-0382](https://rustsec.org/advisories/RUSTSEC-2026-0382)
- [uv system certificate setting](https://docs.astral.sh/uv/reference/settings/#system-certs)
- [Deno's merged eMudhra distrust change](https://github.com/denoland/deno/pull/37046)
- [Go's intermediate CA distrust fix](https://github.com/golang/go/issues/82345)
- [Go 1.27.3 Linux system-root lookup](https://github.com/golang/go/blob/go1.27.3/src/crypto/x509/root_linux.go)
- [Deno TLS certificate-store environment variable](https://docs.deno.com/runtime/reference/env_variables/)
- [Tailscale v1.104.2 release](https://github.com/tailscale/tailscale/releases/tag/v1.104.2)
