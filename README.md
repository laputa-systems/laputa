# mdevd

Linux Rust replacement for the mdevd hotplug daemon and the
`mdevd-coldplug` helper. It listens for kernel uevents on netlink,
creates device nodes and aliases from an mdev-compatible config file,
and rebroadcasts processed events for libudev-zero consumers.

## Run

```
mdevd -f /etc/mdev.conf -d /dev -s /sys -O 4 -D <ready-fd> -o <out-fd>
mdevd -N -f /etc/mdev.conf -d /dev -s /sys   # validate config and exit
mdevd-coldplug -s /sys [-O <nlgroup>]
```

Rules live in `/etc/mdev.conf`; see `tests/fixtures/laputa-mdev.conf`
for the Laputa policy this build accepts. Command-carrying rules and
firmware loading are refused by design, and `-N` validates without
mutating anything. Runtime behavior, verification, and the release
contract live in `docs/`.

## License

ISC; see `COPYING`. Retains Laurent Bercot attribution (`AUTHORS`).
