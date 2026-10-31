#!/bin/xsh
let fd = env.get("NOTIFY_FD")?
unix.exec(process.command_argv(/usr/bin/seatd, ["seatd", "-g", "seat", "-l", "info", "-n", fd], env: {PATH: "/usr/local/bin:/usr/bin:/bin", SEATD_VTBOUND: "0"}))?
