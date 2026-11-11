##! Stop or start the configured xinit services for a backup window.

## Default service transition timeout in milliseconds.
export const QUIESCE_DEFAULT_TIMEOUT_MS = 30000
## Maximum service transition timeout in milliseconds.
export const QUIESCE_MAX_TIMEOUT_MS = 3600000
## The xinit per-service state directory.
export const QUIESCE_STATE_DIR = p"/run/xinit"

const QUIESCE_USAGE = """usage: backup-quiesce <stop|start> SERVICE... [--timeout-ms N]"""

type QuiesceOptions = {action: Str, services: List[Str], timeout_ms: Int, help: Bool}

pure quiesce_options(argv: List[Str]) -> Result[QuiesceOptions, Str] {
  var options = QuiesceOptions(action: "", services: [], timeout_ms: QUIESCE_DEFAULT_TIMEOUT_MS, help: false)
  var index = 0
  while index < argv.len() {
    let word = argv[index]
    index += 1
    if word == "--help" or word == "-h" or word == "help" {
      options.help = true
      continue
    }
    if word == "--timeout-ms" {
      guard index < argv.len() else {
        return Err("--timeout-ms requires a value")
      }
      let value = match argv[index].parse_int() {
        Ok(parsed) => parsed,
        Err(_) => { return Err("--timeout-ms requires an integer") },
      }
      index += 1
      guard value >= 1 and value <= QUIESCE_MAX_TIMEOUT_MS else {
        return Err(f"--timeout-ms must be 1..{QUIESCE_MAX_TIMEOUT_MS}")
      }
      options.timeout_ms = value
      continue
    }
    if word.starts_with("-") {
      return Err(f"unknown option {word}")
    }
    if options.action == "" {
      guard word == "stop" or word == "start" else {
        return Err("action must be stop or start")
      }
      options.action = word
      continue
    }
    guard ! (word in options.services) else {
      return Err(f"duplicate service {word}")
    }
    options.services += [word]
  }
  if options.help {
    return Ok(options)
  }
  guard options.action != "" else {
    return Err("an action is required")
  }
  guard ! options.services.is_empty() else {
    return Err("at least one service is required")
  }
  Ok(options)
}

proc quiesce_status(service: Str) [fs, error] -> Result[Record?, Error] {
  let target = fp"{QUIESCE_STATE_DIR}/{service}.json"
  if ! target.exists() {
    return Ok(null)
  }
  let value = json.read(target)?
  Ok(value.require(Record)?)
}

pure quiesce_down(value: Record?) -> Bool {
  if value == null {
    return true
  }
  let desired = json.get(value, ["desired"], "down").require(Str) ?? "down"
  let state = json.get(value, ["state"], "down").require(Str) ?? "down"
  desired == "down" and (state == "down" or state == "stopped" or state == "dead")
}

pure quiesce_up(value: Record?) -> Bool {
  if value == null {
    return false
  }
  let desired = json.get(value, ["desired"], "down").require(Str) ?? "down"
  let state = json.get(value, ["state"], "down").require(Str) ?? "down"
  desired == "up" and state == "running"
}

proc quiesce_wait(service: Str, up: Bool, timeout_ms: Int) [fs, time, error] -> Result[Unit, Error] {
  var waited = 0
  while true {
    let value = quiesce_status(service)?
    if up {
      if quiesce_up(value) {
        print f"quiesce service={service} desired=up state=running"
        return Ok()
      }
    } else {
      if quiesce_down(value) {
        print f"quiesce service={service} desired=down state=down"
        return Ok()
      }
    }
    guard waited < timeout_ms else {
      let wanted = if up { "up" } else { "down" }
      return Err(error.failure(f"service {service} did not reach {wanted} in {timeout_ms}ms"))
    }
    time.sleep(100ms)?
    waited += 100
  }
}

proc quiesce_main(...argv: List[Str]) [fs, process, time, io, error] -> Result[Unit, Error] {
  let parsed = match quiesce_options(argv) {
    Ok(value) => value,
    Err(problem) => {
      eprint f"backup-quiesce: {problem}"
      eprint $QUIESCE_USAGE
      exit 2
    }
  }
  if parsed.help {
    print $QUIESCE_USAGE
    return Ok()
  }
  let verb = if parsed.action == "stop" { "stop" } else { "start" }
  for service in parsed.services {
    let scratch = p"/run/laputa-backup"
    scratch.mkdir(parents: true)?
    let out = fp"{scratch}/quiesce-{service}.out"
    let errors = fp"{scratch}/quiesce-{service}.err"
    out.remove(missing_ok: true)?
    errors.remove(missing_ok: true)?
    let status = process.run(process.command_argv(
      p"/usr/bin/xinit",
      ["xinit", verb, service],
      cwd: p"/",
      stdin: p"/dev/null",
      stdout: out,
      stderr: errors,
    ))?
    let errors_text = if errors.exists() { errors.read_text()? } else { "" }
    out.remove(missing_ok: true)?
    errors.remove(missing_ok: true)?
    guard status.ok else {
      return Err(error.failure(f"xinit {verb} {service} failed: {errors_text.trim()}"))
    }
    quiesce_wait(service, verb == "start", parsed.timeout_ms)?
  }
  Ok()
}

## Entry point when this module runs as a script.
export proc main(...argv: List[Str]) [fs, process, time, io, error] -> Result[Unit, Error] {
  quiesce_main(@argv)
}
