# Resources

A deployment module exports one pure function:

```xsh
export pure resources() -> List[model.Resource]
```

It declares resources and never touches a host. Resource IDs are unique within
a deployment. `requires` lists resource IDs that must be applied first, and
`hosts` limits a resource to host names or groups. A resource with an empty
`hosts` list applies to every selected host.

Every resource except `ServiceResource` accepts `notify`, which names service
resource IDs to run once after the resource changes. A service `on_change`
selects `reload` or the default `restart`.

## Resource table

| Resource | Required fields | Defaults and behaviour |
|---|---|---|
| `Directory` | `id`, `path` | Mode `0755`. Creates one directory below an existing trusted parent. `absent` removes an empty directory only. |
| `File` | `id`, `path`, `source` when present | Mode `0644`. Exactly one source variant. Stages beside the destination, verifies digest and type, runs an optional validator, then promotes with `mv -T`. |
| `Symlink` | `id`, `path`, `target` | Creates a symbolic link. The target may be relative, including `..`. A different target or a non-link is `blocked` unless `replace: true`. There is no mode or owner. |
| `Package` | `id`, `name` | `apk` package. `constraint` accepts an exact version or `<`, `<=`, `>`, `>=`, or `~`. `refresh_index` runs `apk update` only during apply; refresh is not a separate report row. |
| `UserResource` | `id`, `name` | Creates with `useradd`; supports `uid`, `gid`, `groups`, `home`, `shell`, `system`, and `create_home`. Existing home, shell, or group changes require `update: true`. UID and GID changes are blocked. `absent` never removes a non-empty home. |
| `GroupResource` | `id`, `name` | Creates with `groupadd`; supports `gid` and `system`. `absent` runs `groupdel`. |
| `CommandResource` | `id`, and `argv` or `shell` | Unchanged when `creates` exists or `unless_argv` exits zero. `always_run` runs it every apply. `timeout` bounds the command. |
| `ServiceResource` | `id`, `name` | OpenRC service. `state` is `started` or `stopped`; `enabled` controls the default runlevel; `on_change` is `restart` or `reload`. |

Package names accept Alpine syntax, including `+` and a repository tag such as
`foo@edge`. A tag selects the repository for install and is stripped for the
installed-package lookup and removal.

## File sources

A present file uses one of four variants:

| Variant | Meaning |
|---|---|
| `model.Source(path)` | A local artifact relative to the deployment directory. The loader records its SHA-256. |
| `model.Content(text)` | Inline text. The loader records its SHA-256. |
| `model.Templated(template)` | A template path and string variables, rendered locally before any host call. |
| `model.Secret(reference)` | `FromEnv` or `FromFile`, resolved only at apply. Never written to a plan or report. |

`validate` names a remote validator. Its argv receives the staged path as the
last argument. A non-zero exit keeps the live file and skips promotion. For a
root-owned file the validator also runs through `doas` or `sudo`.

An absent file removes the live file. It does not remove a directory or follow
a symlink.

## Commands

`argv` is executed directly. `shell` runs through `/bin/sh -c`. `env` entries
are passed through `env` and are visible to the remote process; do not put
secrets there. `stdin_secret` streams resolved secret bytes to stdin.

A command with `creates` is unchanged when the path exists. A command with
`unless_argv` is unchanged when that argv exits zero. `always_run` runs the
command on every apply; a command with neither guard nor `always_run` is
rejected. Planning reads `creates` and refuses to run `unless_argv`, so an
unrun guard is `unknown` and cannot be saved.

## Users and groups

Primary group membership follows shadow semantics. A `gid` selects an existing
group by numeric ID. Without `gid`, a user uses an existing group with the same
name rather than failing on the duplicate. Supplementary groups are added with
`usermod -a -G`.

A present user with a differing UID or GID is blocked, because changing either
rewrites ownership across the host. Set `update: true` to allow home, shell, and
supplementary group changes.

A failed privilege escalation is reported as `failed` or `partial` from the
observed account state. It is never reported as success.

## Services and notifications

A service resource starts or stops the service and, when `enabled` is not null,
adds or removes it from the default runlevel. A service that is already in the
requested state is unchanged.

Several changed resources that notify the same service cause one restart or
reload per host. A notification runs after the resource changes; the service
must be declared as a `ServiceResource` with that ID. The restart is folded
into that service's result row.

## Privilege

| Resource kinds | Default privilege |
|---|---|
| `Directory`, `File`, `Symlink`, `CommandResource` | Applying user |
| `Package`, `UserResource`, `GroupResource`, `ServiceResource` | Root |

Set `privilege: model.AsRoot` on a file or directory under `/etc` or another
root-owned tree. Set `privilege: model.AsUser` only when the remote user truly
owns the object.
