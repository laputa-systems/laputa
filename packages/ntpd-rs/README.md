# ntpd-rs clock service

The package installs `ntp-daemon`, `ntp-ctl`, and `ntp-metrics-exporter` with
Graviola and RustCrypto on musl. It installs an xinit service but does not add
it to a profile. The launcher uses numeric UID and GID 123 and retains only
`CAP_SYS_TIME` across exec, with no new privileges. It creates
`/run/ntpd-rs` for the observation socket. Baselayout reserves that identity; the launcher rejects a missing or
mismatched account or group before changing ownership. Existing installations
must provision it before enabling the service. The daemon needs procfs mounted for the readiness pipe.

The launcher reads `/etc/ntpd-rs/ntp.toml` when present and otherwise uses
`/usr/share/ntpd-rs/ntp.toml`. The packaged configuration uses four pool
sources and requires three agreeing sources. It permits an unlimited initial
forward step, limits the initial backward step to one day, and limits a later
single step to 1000 seconds; exceeding a configured limit stops the daemon.
Readiness means configuration and observation socket initialization, not clock
synchronization. `ntp-ctl status -c PATH` shows stratum 16 without a selected
source. The service status reports the stratum using the selected configuration.
No drift state is persisted by this package.

The default pool is unauthenticated NTP and cannot establish authenticated time.
The package manager currently persists the observed wall clock after a signed
snapshot is accepted, regardless of the clock source. An unauthenticated NTP
step can therefore advance that floor; R2/R4 still need a policy that prevents
this before the package is used for authenticated production delivery. NTS configuration
requires a clock sufficiently accurate to validate the server certificate; an
operator must restore a trustworthy clock when cold boot or a long offline
period leaves it outside that window. The package does not provide an
authenticated bootstrap or persistence policy. Do not disable certificate
verification or bypass release expiry to recover.

Graviola requires `aes`, `pclmulqdq`, `bmi1`, `adx`, `avx`, and `avx2` on
x86_64; AArch64 requires `neon`, `aes`, `pmull`, and `sha2`. Laputa's QEMU
configuration selects the host CPU, but actual guest feature exposure depends
on the host and hypervisor and must be checked for each deployment. Missing
features cause Graviola to panic. Guest clock discipline, pause and jump
recovery, and the privilege boundary still require disposable-guest proof.
