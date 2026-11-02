#!/bin/xsh
unix.exec(process.command_argv(p"/usr/bin/tinyland", ["tinyland", "--seat", "--", "/usr/bin/ghostty-custom"]))?
