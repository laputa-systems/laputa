#!/bin/xsh
unix.exec(process.command_argv(/usr/bin/tinyland, ["tinyland", "--seat", "--", "/usr/bin/ghostty-custom"]))?
