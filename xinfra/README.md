# xinfra

xinfra is a small configuration-management tool for Alpine hosts. It loads a
typed inventory and deployment, compares desired state with observed state, and
applies directories, files, symlinks, `apk` packages, users, groups, commands,
and OpenRC services over a native SSH connection.

The controller runs XSH scripts. The managed host needs a POSIX shell, BusyBox,
`apk`, OpenRC, and the shadow account tools. It does not need Python, an agent,
or a daemon.

## Requirements

- XSH with the `ssh` module. Every xinfra command loads that module, so an XSH
  build without it fails at startup.
- Alpine 3.23 or a compatible BusyBox/OpenRC host.
- An unencrypted Ed25519 SSH key for the remote account.
- Passwordless `doas` or `sudo` for resources that run as root.
- A pinned `SHA256:` host-key fingerprint for every inventory host.

## Install

From a source checkout:

```sh
make package
make install PREFIX=$HOME/.local
```

The installed `$PREFIX/bin/xinfra` wrapper runs the library under
`$PREFIX/libexec/xinfra` with `${XSH:-xsh}`. Set `XSH` to choose a specific XSH
binary:

```sh
XSH=/path/to/xsh xinfra --version
```

You can also unpack the tarball and run `./install.sh /usr/local`.

## Quick start

Create an inventory. The key path is relative to the inventory file:

```toml
groups = ["web"]

[[hosts]]
name = "web-1"
groups = ["web"]
address = "203.0.113.10"
port = 22
user = "deploy"
key = "keys/deploy_ed25519"
host_key = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
```

Create a deployment module. A deployment only declares resources:

```xsh
use xinfra.model

export pure resources() -> List[model.Resource] {
  [
    model.Package(model.PackageSpec(id: "nginx-pkg", name: "nginx")),
    model.File(model.FileSpec(
      id: "motd",
      path: p"/etc/motd",
      source: model.Content("managed by xinfra\n"),
      owner: "root",
      group: "root",
      privilege: model.AsRoot,
    )),
    model.ServiceResource(model.ServiceSpec(
      id: "nginx",
      name: "nginx",
      state: model.Started,
      enabled: true,
      requires: ["nginx-pkg"],
    )),
  ]
}
```

Then plan, check, and apply:

```sh
xinfra plan --inventory inventory.toml --deploy deploy.xsh
xinfra check --inventory inventory.toml --deploy deploy.xsh
xinfra apply --inventory inventory.toml --deploy deploy.xsh
```

`plan` and `check` never mutate the host. `apply` stages file content beside
the destination, verifies it, and promotes it atomically. A second apply is a
no-op unless a command sets `always_run`.

Read [resources](docs/resources.md) to write deployments,
[operations](docs/operations.md) to run them, [security](docs/security.md) for
trust and secrets, and [platform](docs/platform.md) for supported systems.

## Commands

| Command | Purpose |
|---|---|
| `doctor` | Validate the inventory and deployment and list selected hosts. |
| `plan` | Compute ordered actions without touching a host. |
| `check` | Report drift; exit 1 when any action is needed. |
| `apply` | Apply the plan with the selected failure policy. |
| `unlock` | Remove one host lock with an explicit force flag. |

Run `xinfra --help` or `xinfra <command> --help` for options. `--format`
selects human, JSON, or JSONL output; [operations](docs/operations.md) documents
the report schema and exit codes.

## Help

Report problems at <https://github.com/laputa-systems/xinfra/issues>.

## License

xinfra is released under the [MIT License](LICENSE). Third-party notices are
in [NOTICE](NOTICE).
