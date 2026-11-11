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

## XSH dialect (Laputa)

An `xsh` target runs the catalogue's XSH source under `xsh-login`. The sources
depend on these standard APIs, all present in the pinned profile:

1. `fs.stat(path, follow_symlinks: false)` returns the full `st_mode` in `mode`,
   the entry kind, `uid`, `gid`, `size` and `mtime_ns`; a failure carries
   `errno`, which the path probe uses to separate `ENOENT` (missing), `ENOTDIR`
   (blocked) and `EACCES` (denied) from other errors.
2. `fs.set_owner`, `fs.symlink`, `fs.mknod` with `kind: "file"` and mode `0o600`,
   `fs.temp_sibling`, `fs.open_root` with `FsRoot.mkdir(mode:, parents:)`, and
   `Path.write/rename/chmod/readlink/remove_dir/unlink`. `fs.mknod` fails rather
   than replacing an existing path, which is what makes the staging file an
   exclusive create.
3. `hash.sha256(path)` for the file digest, and `user.by_uid`, `group.by_gid`,
   `user.lookup`, `group.lookup` for owner and group names and numeric ids.
4. `process.which`, `process.run` with `process.command_argv`, `run.capture`,
   `io.stdin_bytes` and `io.write_stdout_bytes` for argv commands, the xinit
   control plane, the status probe and streamed file content.
5. `fs.tempfile()` returns a record whose `path` is the file name inside the
   returned `FsRoot`, not an absolute path. A caller that needs to execute the
   file must build `root.host_path() + path`; the local xsh runner does.
6. `fs.tempdir()` and `fs.tempfile()` roots are closed by their owning scope,
   so the local xsh runner keeps the record alive until the child exits.
