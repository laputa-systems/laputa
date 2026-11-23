#!/bin/xsh
unix.exec(process.command_argv(p"/usr/bin/tinyland", ["tinyland", "--seat", "--", "/bin/xsh", "/usr/lib/laputa/tinyland-play-client.xsh"]))
