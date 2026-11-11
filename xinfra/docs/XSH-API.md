# Requirements on XSH

What xsh-infra relies on in XSH `master`. xsh-infra does not edit XSH; an API need or defect found here is recorded in this file.

## Native SSH (XSH-55)

1. Typed SSH failures. `ssh.connect` and `ssh.exec` fail with an `SshError`
   variant per failure kind, and every variant carries `message` and
   `certainty`, an `ssh.Certainty` (`NotSubmitted` or `Submitted`).
   `transport.certainty_of` reads it with `ssh.certainty`; no message text is
   matched.
2. Exec environment. xsh-infra does not use the `env` option. A refused name
   fails the whole request, and OpenSSH accepts only the names `AcceptEnv`
   lists, so asking for `LC_ALL` would turn a host without that line into a
   failed host. The constant scripts set `LC_ALL=C` themselves, which holds on
   every server and through `doas`.
3. Session lifetime in collections. A session stored in a `Map` outlives the
   `proc` that opened it and is usable from `par-map` workers. xsh-infra relies
   on this to reuse one authenticated connection across observation and
   mutation; keep it a stated guarantee. `SshSession` is opaque, so a session
   is only ever the value `ssh.connect` or `ssh.connect_all` returned.
4. `ssh.connect_all` opens every host of an apply in parallel. A session lost to
   a timeout reports `usable = false` from `ssh.info`, and later calls fail with
   `SshError.Unusable` and `certainty = .NotSubmitted`; `transport.usable`
   lets the lock release reconnect instead of trying a dead session.
