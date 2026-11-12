# Security

Laputa's security posture is carried by package payload metadata, generation
receipts, activation policy, and the first-boot writer. This page records the
filesystem modes those owners enforce for identity material.

## Credential file modes

`/etc/shadow` is mode `0600`, owned by `root:root`. The baselayout group file
has no `shadow` group, so `0640 root:shadow` would invent a group with no
consumer; only root reads password hashes. The mode is enforced by the owners
rather than inherited from the checkout:

- `packages/baselayout/PKGBUILD.xsh::build` sets `etc/shadow` to `0600` in the
  package payload. PM records the payload mode in artifact metadata, and root
  composition and generation extraction apply it with `modes: .Exact`.
- `system/first_boot.xsh::ensure_account` writes `etc/shadow` with mode `0600`
  and tightens an existing file whose mode drifted, whether or not that apply
  appends the operator record.

`/etc/passwd`, `/etc/group`, `/etc/shells`, and `/etc/doas.conf` stay `0644`:
they carry password placeholders, group membership, or public privilege
policy, not hashes or keys. The operator's `authorized_keys` is `0600`.
`/etc/laputa/trust-update-key` and `/etc/laputa/repo-snapshot-keys` are `0444`
because they are public verification keys.

The baselayout payload and its tarball are covered by
`tests/pm/linux_recipe.xsh`, the first-boot writer by
`tests/system/first_boot.xsh`, and a booted guest and its restored state disk
by `tests/integration/g2_lifecycle.py` through
`stat -c %a:%U /etc/shadow`.
