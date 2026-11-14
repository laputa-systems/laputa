#!/bin/xsh
##! Root control agent for the backup recovery guest. It reads one JSON request per line
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

proc run_argv(argv: List[Str], limit_s: Int) -> Result[Record, Error] {
  let out = p"/run/recovery-agent.out"
  let err = p"/run/recovery-agent.err"
  let status = process.run(process.command_argv(
    argv[0],
    argv,
    cwd: p"/",
    env: {XSH_MODULE_PATH: "/usr/lib/xsh/core"},
    stdout: out,
    stderr: err,
    timeout: time.millis(limit_s * 1000),
  ))?
  {exit: status.exit_code()?, stdout: text_of(out, 65536)?, stderr: text_of(err, 8192)?}
}

proc service_view(name: Str) -> Result[Record, Error] {
  {
    service: optional_json(fp"/run/xinit/{name}.json")?,
    control: text_of(fp"/run/xinit/{name}.control", 256)?.trim(),
    queued: fp"/run/xinit/inbox/{name}".exists()?,
  }
}

proc observation(names: List[Str], files: List[Str]) -> Result[Record, Error] {
  var services: Map[Record] = {}
  for name in names {
    services[name] = service_view(name)?
  }
  var contents: Map[Str] = {}
  for file in files {
    contents[file] = text_of(Path(file), 65536)?
  }
  {
    services: services,
    files: contents,
    boot_id: text_of(p"/proc/sys/kernel/random/boot_id", 128)?.trim(),
    wall_ms: time.now(),
    boot_ns: time.boottime()?,
    scheduler: optional_json(p"/run/xinit/laputa-timers.json")?,
    scheduler_log: text_of(p"/var/log/laputa-timers/current", 262144)?,
  }
}

proc handle(fd: Int, line: Str) -> Result[Unit, Error] {
  let request = json.decode(line)?.require(Record)?
  let op = json.get(request, ["op"], "").require(Str)?
  if op == "ping" {
    reply(fd, {ok: true})?
  } else if op == "exec" {
    let argv = json.get(request, ["argv"], []).require(List[Str])?
    let limit = json.get(request, ["limit_s"], 30).require(Int)?
    reply(fd, {ok: true, result: run_argv(argv, limit)?})?
  } else if op == "observe" {
    let names = json.get(request, ["services"], []).require(List[Str])?
    let files = json.get(request, ["files"], []).require(List[Str])?
    reply(fd, {ok: true, observation: observation(names, files)?})?
  } else {
    reply(fd, {ok: false, error: f"unknown operation {op}"})?
  }
}

proc main() -> Result[Unit, Error] {
  let port = control_port()?
  let control = unix.open_fd(port, write: true, nonblock: false)?
  p"/dev/console".write(f"LAPUTA_RECOVERY_AGENT_READY {port.display()}\n")?
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
    let _ = p"/dev/console".write(f"LAPUTA_RECOVERY_AGENT_FAILED {problem.message}\n")
  }
}
