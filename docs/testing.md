# Local verification

| Command | Evidence |
| --- | --- |
| `cargo test --locked -q -- adversarial` | Ancestor confinement, leaf symlink refusal, netlink truncation and spoof flood, output backpressure, restart during coldplug |
| `tools/check-privileged.sh` | Real character and block nodes, identity adoption, modes, ownership, aliases, replacement safety, FD stability, kernel-event publication |
| `cargo test --locked -q --test engine --test bins --test parity` | Engine behavior, daemon lifecycle, C-oracle comparisons |
| `cargo clippy --locked -q --all-targets` | Rust lint checks |

`tools/check-privileged.sh` requires Linux x86_64, the pinned Rust toolchain,
Docker access, a local `ubuntu:24.04` image, BusyBox at `/bin/busybox`,
and the musl loader at `/lib/ld-musl-x86_64.so.1`.
The script rebuilds the C oracle and compiles static musl test binaries.
A missing prerequisite or failed test fails the command.
The privileged tests are explicitly ignored by ordinary Cargo runs.

Both containers mount the repository read-only and overlay `.work/tmp` with private tmpfs.
The device container receives only `MKNOD`, `CHOWN`, and `FOWNER` capabilities.
The kernel-event container receives only `NET_ADMIN` and uses a private network namespace.
Neither container receives host device mounts or host networking.

The kernel test creates and removes a dummy interface through rtnetlink.
Both C and Rust daemons receive genuine kernel events, including interface queue events.
The test compares every captured kernel datagram with the daemon's `-o` framing and `-O 4` rebroadcast, in order.
It waits for `-D` readiness before triggering events and requires clean SIGTERM exit.
A FIFO handshake holds reload open while the kernel queues add events.
It never writes host sysfs.

Network events lack device major and minor numbers, so this test does not exercise daemon-driven device creation.
The device tests exercise the real filesystem adapter on private tmpfs instead.
RealOps rejects symlink ancestors for mutations and retains the verified device inode for subsequent metadata changes.
Its chmod implementation requires `/proc/self/fd` to update that inode without opening the device.
