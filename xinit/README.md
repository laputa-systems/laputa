# xinit

`xinit` is a pure XSH init and service supervisor script.

It lives in the Laputa monorepo and uses the XSH tools from the sibling
checkout at `XSH_ROOT` (default `../xsh` from the monorepo root). From the
monorepo root:

```sh
make test-xinit
```

## Commands

```sh
xsh xinit/xinit.xsh -- /etc/inittab
xsh xinit/xinit.xsh -- boot
xsh xinit/xinit.xsh -- start SERVICE
xsh xinit/xinit.xsh -- restart SERVICE
xsh xinit/xinit.xsh -- status SERVICE
xsh xinit/xinit.xsh -- logs SERVICE
xsh xinit/xinit.xsh -- stop SERVICE
xsh xinit/xinit.xsh -- list
xsh xinit/xinit.xsh -- graph SERVICE_OR_TARGET
xsh xinit/xinit.xsh -- check [SERVICE_OR_PATH]
```

See `docs/INIT.md` for the full contract.
