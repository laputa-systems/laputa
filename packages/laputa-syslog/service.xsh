##! xinit service for the maintained profile's local syslog receiver.
##!
##! The receiver is a foreground process: it publishes /dev/log, writes the
##! readiness byte once the socket is bound, and writes one escaped line per
##! message to stdout, which xinit captures to /var/log/logger/current on the
##! maintained state disk. Four levels stay separate: the process runs
##! (`state`, `pid`), the socket is ready (the notify byte, shown as `ready`),
##! messages are being accepted (`socket=` below), and nothing claims that logs
##! reach a remote host. Log rotation is xinit's copy-truncate path, so the
##! receiver keeps writing the same inode across rotation.
##!
##! Delivery is not lossless: the kernel drops datagrams from a full socket
##! queue without telling the receiver, and the receiver drops by rate, size,
##! descriptor passing and an unwritable sink, and counts each. No fleet
##! observability layer is implied.

## The exact syslogd invocation for the maintained profile. State (the
## exclusive lock) lives in /run; the socket is published at /dev/log.
export pure syslogd_argv() -> List[Str] {
  ["syslogd", "--state", "/run", "--socket", "/dev/log"]
}

## The xinit service record. Services that need a logger name it in `need`,
## which then waits for the readiness byte, so /dev/log exists before they
## start. Boot-critical services stay off that gate so a logger failure can
## never hold back rescue or login.
export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv(/usr/bin/syslogd, syslogd_argv()),
  targets: [
    "boot",
  ],
  readiness: "notify",
  ready_timeout_ms: 5000,
  stop_timeout_ms: 2000,
  restart: {
    mode: "always",
    delay_ms: 500,
    max_delay_ms: 30000,
    stable_after_ms: 10000,
  },
  logging: "append",
}

## Reports whether the socket is published and who owns it. A missing or
## foreign entry shows up here even while the process is still running.
export proc status() [fs, process, env, error] -> Result[Str, Error] {
  if let Ok(info) = fs.stat(p"/dev/log") {
    Ok(f"socket={info.kind} mode={info.mode.bit_and(0o777)}")
  } else {
    Ok("socket=absent")
  }
}
