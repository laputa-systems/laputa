#!/bin/xsh
let fd = env.get("NOTIFY_FD")?
unix.exec(process.command_argv(/usr/bin/mdevd, ["mdevd", "-O", "4", "-f", "/etc/mdev.conf", "-D", fd], env: {PATH: "/usr/local/bin:/usr/bin:/bin"}))?
