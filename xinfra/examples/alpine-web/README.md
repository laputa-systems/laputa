# Alpine web host

`deploy.xsh` takes a fresh Alpine host to: `lighttpd` installed; group and user
`webops` (member of `wheel`, shell `/bin/ash`); `/srv/www` owned by `webops`; an
`index.html` and a `lighttpd.conf` rendered from `files/*.tmpl` with the host's
`port` and `title` variables; the configuration checked with `lighttpd -tt`
before it replaces the live file; a symlink `current.html`; and the `lighttpd`
OpenRC service enabled and running, reloaded when the page changes and restarted
when the configuration changes.

Run from the repository root (template paths are relative to it):

```sh
xinfra doctor examples/alpine-web/inventory.example.toml
xinfra plan   INVENTORY examples/alpine-web/deploy.xsh
xinfra apply  INVENTORY examples/alpine-web/deploy.xsh
xinfra apply  INVENTORY examples/alpine-web/deploy.xsh     # changes nothing
```

`inventory.example.toml` shows the shape; put your own host, key path and
SHA256 pin in a private copy. Nothing in this repository holds a key or secret.

Expected behavior, shown by the Alpine test suite and a run against two
disposable hosts: the first apply reports the package, group, user, directory,
files, link and service `changed` and verified; the second reports every
resource `unchanged`; editing `/srv/www/index.html` on a host makes `check` exit
1 with `web-page` drifting and the service shown `(conditional)` for a reload,
and `apply` restores it and reloads the service once. Without the validator
passing, `/etc/lighttpd/lighttpd.conf` keeps its old content.
