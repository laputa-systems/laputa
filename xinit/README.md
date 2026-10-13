# xinit

`xinit` is a pure XSH init and service supervisor script, Laputa's PID 1. The
`xinit` package installs `xinit.xsh` as `/usr/bin/xinit` with `/init` linking
to it.

## Commands

```sh
xinit [INITTAB]
xinit boot [TARGET]
xinit scan [SERVICE|TARGET]
xinit <start|up|stop|down|restart|reload|status|logs|supervise> SERVICE
xinit list
xinit graph [SERVICE|TARGET]
xinit check [SERVICE|PATH]
```

See the [init contract](docs/INIT.md) for configuration and
[supervision model](docs/SUPERVISION.md) for scanner design.
Developer checks are covered in [testing](../docs/TESTING.md).
