# Laputa

Laputa is a small Linux distribution for aarch64 and x86_64, using musl and
XSH for its package manager, recipes, init system, installer, and system tools.

## Get and run it

The current installer workflow uses locally built packages and runs in QEMU.
Obtain the checkout and prepare its local packages using the
[bootstrap instructions](docs/DEVELOPMENT.md#local-bootstrap), then, on aarch64 with host XSH on `PATH` and the local mirror running, run:

```sh
XSH_MODULE_PATH="$PWD" make installer-qemu-manual
```

Inside the guest, run `setup-laputa` to choose an installation disk, or
`setup-laputa --ci` for the harness's small test disk. Installation repartitions
the selected disk. The installed system creates user `pazu`, serial and tty1
autologin, and passwordless wheel sudo.

The manual harness writes its ISO, matching kernel, and target disk under
`target/laputa-installer/`. Image creation and the automated installation
proof (`make installer-qemu-test`) support both architectures and write under
`target/laputa-installer-<arch>/` and `target/laputa-installer-<arch>-qemu/`. The current harness boots the kernel directly;
standalone firmware boot of the ISO is not yet supported by this workflow.
See the [installer guide](docs/INSTALLER.md) for host requirements and boot
limitations.

For a dwl desktop with the foot terminal, after preparing the seed run:

```sh
make profile-boot
```

This builds and boots the `qemu-dwl-foot` profile for the host architecture.
It uses KVM on Linux or HVF on Apple Silicon macOS and stores the system under
`target/laputa/qemu-dwl-foot/`. The [QEMU guide](docs/QEMU.md) covers requirements
and outputs. A headless Asterinas/Firecracker guest is also available on
x86_64 Linux; see [Asterinas](docs/ASTERINAS.md).

## Packages and services

`pm` works with explicit plans and immutable runtime generations. It has no
default remote repository. Set `XSH_PM_REPO` to a mirror URL to plan against
its package index; leave it empty for offline planning. Publishing to an
authenticated mirror also needs `LAPUTA_TOKEN`. Run `pm --help` for commands
and see the [PM contract](docs/PM.md#commands) for examples.

`xinit` manages services, for example:

```sh
xinit list
xinit status SERVICE
xinit start SERVICE
xinit stop SERVICE
```

The [xinit guide](xinit/docs/INIT.md) covers service configuration and output.
The [mirror guide](mirror/README.md) covers running a package mirror.

## Help and licensing

Use the linked command guides and `pm --help` for usage. When reporting a
problem to the maintainers, include the command, host architecture, and relevant
output.

This checkout has no repository-wide license file. Package recipes declare
upstream licenses individually.
