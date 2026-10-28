##! Reference xinit service for the XSH local syslog receiver.
##!
##! The receiver is a foreground process: it publishes /dev/log, writes the
##! readiness byte once the socket is bound, and writes one escaped line per
##! message to stdout, which xinit captures. Four levels stay separate: the
##! process runs (`state`, `pid`), the socket is ready (the notify byte, shown
##! as `ready`), messages are being accepted (`socket=` below), and nothing
##! claims that logs reach a remote host.

## The xinit service record. Services that need a logger name it in `need`, which
## then waits for the readiness byte, so /dev/log exists before they start.
export let service = {
  name: "logger",
  kind: "longrun",
  command: process.command_argv("syslogd", ["syslogd", "--state", "/run", "--socket", "/dev/log"]),
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

## Reports whether the socket is published and who owns it. A missing or foreign
## entry shows up here even while the process is still running.
export proc status() [fs, process, env, error] -> Result[Str, Error] {
  if let Ok(info) = fs.stat(p"/dev/log") {
    Ok(f"socket={info.kind} mode={info.mode.bit_and(0o777)}")
  } else {
    Ok("socket=absent")
  }
}
