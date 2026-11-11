#!/bin/xsh
##! Root control agent for the timers guest. It reads one JSON request per line
##! from a virtio-serial port and answers with one JSON line. It never uses the
##! network under test, so it survives a clock step, a pause, and a reboot.

proc control_port() -> Result[Path, Error] {
  let named = p"/dev/virtio-ports/laputa-ctl"
  var waited = 0
  while ! named.exists()? and waited < 10000 {
    time.sleep(100ms)
    waited += 100
  }
  if named.exists()? { return Ok(named) }
  for entry in fs.children(p"/dev")? {
    if entry.name.starts_with("vport") and entry.name.ends_with("p1") {
      let label = fp"/sys/class/virtio-ports/{entry.name}/name"
      if label.exists()? and label.read_text()?.trim() == "laputa-ctl" { return Ok(entry.path) }
    }
  }
  Err(error.failure("no virtio-serial control port"))
}

proc reply(fd: Int, value: Any) -> Result[Unit, Error] {
  let _ = unix.write_fd(fd, bytes.from_text(json.encode(value)? + "\n"))?
}

proc text_of(source: Path, limit: Int) -> Result[Str, Error] {
  return Ok("") unless source.exists()?
  let text = source.read_text()?
  return Ok(text) when text.byte_len() <= limit
  Ok(text[..limit])
}

proc optional_json(source: Path) -> Result[Any, Error] {
  return Ok(null) unless source.exists()?
  json.read(source)
}

proc read_line(fd: Int) -> Result[Str, Error] {
  var buffer = b""
  while true {
    let ready = unix.poll_fd(fd, ["readable"], 1000)?
    if ready != ["readable"] {
      continue
    }
    let chunk = unix.read_fd(fd, 1)?
    if chunk.is_empty() {
      return Err(error.failure("the control port closed"))
    }
    if chunk.byte_at(0) == 10 {
      return buffer.utf8()?
    }
    buffer = bytes.concat([buffer, chunk])
    if buffer.len() > 65536 {
      return Err(error.failure("the control line is too long"))
    }
  }
  Err(error.failure("unreachable"))
}

proc observation() -> Result[Record, Error] {
  {
    service: optional_json(p"/run/xinit/laputa-timers.json")?,
    status: optional_json(p"/run/laputa-timers/status.json")?,
    state: optional_json(p"/var/lib/laputa-timers/state.json")?,
    boot_id: text_of(p"/proc/sys/kernel/random/boot_id", 128)?.trim(),
    wall_ms: time.now(),
    boot_ns: time.boottime()?,
    interval_log: text_of(p"/var/lib/timers-proof/interval.log", 65536)?,
    calendar_log: text_of(p"/var/lib/timers-proof/calendar.log", 65536)?,
    failing_log: text_of(p"/var/lib/timers-proof/failing.log", 65536)?,
    cancel_marker: p"/var/lib/laputa-timers/cancel/interval".exists()?,
    scheduler_log: text_of(p"/var/log/laputa-timers/current", 65536)?,
  }
}

proc run_timers(arguments: List[Str]) -> Result[Record, Error] {
  let out = p"/run/timers-agent.out"
  let err = p"/run/timers-agent.err"
  let argv = ["xsh", "/usr/lib/laputa/timers.xsh"] + arguments
  let status = process.run(process.command_argv(
    p"/usr/bin/xsh",
    argv,
    cwd: p"/",
    env: {XSH_MODULE_PATH: "/usr/lib/xsh/core"},
    stdout: out,
    stderr: err,
    timeout: 30s,
  ))?
  {exit: status.exit_code()?, stdout: text_of(out, 65536)?, stderr: text_of(err, 8192)?}
}

const remote_request = "{\"protocol\":\"laputa-remote-1\",\"op\":\"run\",\"argv\":[\"/usr/bin/xsh\",\"/usr/lib/laputa/timers.xsh\",\"status\",\"--json\"],\"timeout_ms\":30000}\n"

proc remote_status() -> Result[Record, Error] {
  let request = p"/run/timers-remote-request.json"
  request.write(remote_request)?
  let out = p"/run/timers-remote.out"
  let err = p"/run/timers-remote.err"
  let status = process.run(process.command_argv(
    p"/usr/bin/xsh",
    ["xsh", "/etc/laputa/remote_guest.xsh"],
    cwd: p"/",
    stdin: request,
    stdout: out,
    stderr: err,
    timeout: 60s,
  ))?
  {exit: status.exit_code()?, stdout: text_of(out, 262144)?, stderr: text_of(err, 8192)?}
}

proc xinit_restart() -> Result[Record, Error] {
  let out = p"/run/timers-xinit.out"
  let err = p"/run/timers-xinit.err"
  let status = process.run(process.command_argv(p"/usr/bin/xinit", ["xinit", "restart", "laputa-timers"], cwd: p"/", stdout: out, stderr: err, timeout: 30s))?
  {exit: status.exit_code()?, stdout: text_of(out, 8192)?, stderr: text_of(err, 8192)?}
}

proc handle(fd: Int, line: Str) -> Result[Unit, Error] {
  let request = json.decode(line)?.require(Record)?
  let op = json.get(request, ["op"], "").require(Str)?
  if op == "ping" {
    reply(fd, {ok: true})?
  } else if op == "status" {
    reply(fd, {ok: true, observation: observation()?})?
  } else if op == "timers" {
    let arguments = json.get(request, ["args"], []).require(List[Str])?
    reply(fd, {ok: true, result: run_timers(arguments)?})?
  } else if op == "restart" {
    reply(fd, {ok: true, result: xinit_restart()?})?
  } else if op == "remote" {
    reply(fd, {ok: true, result: remote_status()?})?
  } else {
    reply(fd, {ok: false, error: f"unknown operation {op}"})?
  }
}

proc main() -> Result[Unit, Error] {
  let port = control_port()?
  let control = unix.open_fd(port, write: true, nonblock: false)?
  p"/dev/console".write(f"LAPUTA_TIMERS_AGENT_READY {port.display()}\n")?
  loop {
    let line = read_line(control)?
    if line.trim() == "" {
      continue
    }
    match handle(control, line) {
      Ok(_) => {}
      Err(problem) => {
        let _ = reply(control, {ok: false, error: problem.message})
      }
    }
  }
  Ok()
}

match main() {
  Ok(_) => {}
  Err(problem) => {
    let _ = p"/dev/console".write(f"LAPUTA_TIMERS_AGENT_FAILED {problem.message}\n")
  }
}
