# Agent Guide

Vendored from laputa-systems/xsh-infra at e293bfd; make changes upstream, not here.

xsh-infra is a small configuration-management tool written in XSH. It reconciles
Alpine/Laputa-style hosts over XSH's native SSH client. Policy lives in XSH;
the controller needs a qualified `xsh` and `xsht` and nothing else. Read
[Architecture](docs/ARCHITECTURE.md) before changing a module boundary and
[Usage](docs/USAGE.md) before changing the CLI or the report formats.

## Commands

- Check: `xsht check lib bin tests examples`.
- Test: `xsht test --jobs 16`. Tests that need disposable hosts skip when
  `XINFRA_TEST_INVENTORY` is unset.
- Disposable Alpine hosts: `xsh fixtures/alpine.xsh up`, then
  `XINFRA_TEST_INVENTORY=.work/fixtures/inventory.toml xsht test`, then
  `xsh fixtures/alpine.xsh down`. See [Testing](docs/TESTING.md).
- Use an `xsh` and `xsht` built from XSH `master` (verification profile) and
  put both on `PATH`. Never edit the XSH checkout from here; an API need goes
  in [docs/XSH-API.md](docs/XSH-API.md).

## Rules

- Pure planning, comparison, ordering and parsing stay in `pure` functions.
  Host effects live only in `transport`, `observe`, `mutate` and `lock`.
- Remote execution runs over the native `ssh` module only. No external
  `ssh`, `scp` or `sftp`, no remote Python or `jq`. Remote XSH is allowed only
  for a target whose inventory dialect is `xsh` (Laputa, which has no POSIX
  shell); see docs/ARCHITECTURE.md.
- `shell.quote` and `shell.xsh_quote` are the only places a request value
  becomes remote source. Remote scripts are constants that receive values as
  positional arguments (POSIX) or as the `xinfra_args` literal list (XSH).
- No new language syntax, async runtime or daemon. Deployment programs are
  trusted operator code.
- A language or runtime defect gets a minimal reproducer and a note in
  `docs/XSH-API.md`, not a workaround that hides it.
- Never deploy to real hosts. Fixtures are disposable and use fresh keys.
- Write no comments in code. Put the why in a name, a type, a test, or the
  commit body. Doc comments (`##`) on exports are required by `xsht check`.
- Do not run formatters or autofixers.
- Commits are Conventional Commits (`type(scope): subject`, imperative,
  lowercase, at most 72 characters); the body says why. Commit directly to
  `master`; never push without being asked.
- Scratch and worktrees go under `.work/`, which `.git/info/exclude` ignores.
  Never use `/tmp`.
- Stop only the containers and processes you started, by ID.
