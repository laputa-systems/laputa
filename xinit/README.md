# xinit

`xinit` is a pure XSH init and service supervisor script, Laputa's PID 1. The
`xinit` package installs `xinit.xsh` as `/usr/bin/xinit` with `/init` linking
to it.

It lives in the Laputa monorepo and runs on the XSH tools the root `Makefile`
selects (see the root `README.md`). From the monorepo root:

```sh
make test-xinit
```

## Commands

```sh
xsh xinit/xinit.xsh -- [INITTAB]
xsh xinit/xinit.xsh -- boot [TARGET]
xsh xinit/xinit.xsh -- scan [SERVICE|TARGET]
xsh xinit/xinit.xsh -- <start|stop|restart|reload|status|logs|supervise> SERVICE
xsh xinit/xinit.xsh -- list
xsh xinit/xinit.xsh -- graph [SERVICE|TARGET]
xsh xinit/xinit.xsh -- check [SERVICE|PATH]
```

See `docs/INIT.md` for the full contract and `docs/SUPERVISION.md` for the
supervision model.
