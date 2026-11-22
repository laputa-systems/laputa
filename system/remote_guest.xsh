##! Fixed remote administration program. The admin host sends this exact text as the
##! SSH exec command and one request on stdin: a JSON header line, then payload bytes.
##! It never interpolates request values into source and answers with one JSON line.
const protocol = "laputa-remote-1"
const header_limit = 4096
const name_re = rx"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
const stage_limit = 4294967296
const run_output_limit = 1048576
const run_timeout_limit_ms = 600000
const log_lines = 200
const chunk = 1048576

error RemoteError = Refused(kind: Str, message: Str)

proc refuse(kind: Str, message: Str) -> RemoteError {
  .Refused(kind:, message:)
}

proc read_header() [io, error] -> Result[Record, Error] {
  let line = io.stdin_line()?
  guard line.byte_len() <= header_limit else {
    return Err(refuse("header-too-large", "request header exceeds the limit"))
  }
  let decoded = json.decode(line)?
  guard json.get(decoded, ["protocol"], "") == protocol else {
    return Err(refuse("protocol-version", f"this program speaks {protocol}"))
  }
  decoded.require(Record)?
}

proc maybe_json(file: Path) [fs, error] -> Result[Any, Error] {
  return json.read(file)? when file.exists()
  null
}

type ServiceState = {name: Str, state: Str, restarts: Int}

proc services() [fs, error] -> Result[List[ServiceState], Error] {
  let found: List[ServiceState] = collect {
    for item in g"/run/xinit/*.json" {
      let value = json.read(item)?
      let name = json.get(value, ["name"], "").require(Str)?
      if name != "" {
        yield {
          name: name,
          state: json.get(value, ["state"], "").require(Str)?,
          restarts: json.get(value, ["restarts"], 0).require(Int)?,
        }
      }
    }
  }
  found |> sort-by .name |> collect
}

proc inspect() [fs, error] -> Result[Record, Error] {
  {
    generation: maybe_json(p"/run/laputa-running-generation.json")?,
    health: maybe_json(p"/run/laputa-health.json")?,
    services: services()?,
    kernel: p"/proc/sys/kernel/osrelease".read_text()?.trim(),
    hostname: p"/proc/sys/kernel/hostname".read_text()?.trim(),
  }
}

proc read_log(file: Path, count: Int) [fs, error] -> Result[Record, Error] {
  return {path: file.display(), readable: true, lines: []} unless file.exists()
  if let Ok(text) = file.read_text() {
    let lines = text.lines()
    let kept = if lines.len() <= count { lines } else { lines[lines.len() - count..] }
    {path: file.display(), readable: true, lines: kept}
  } else {
    {path: file.display(), readable: false, lines: []}
  }
}

proc diagnose() [fs, error] -> Result[Record, Error] {
  let all = services()?
  {
    services: all,
    unhealthy: all |> where .state != "running" |> collect,
    logs: [
      read_log(p"/var/log/logger/current", log_lines)?,
      read_log(p"/var/log/boot-markers.log", 20)?,
      read_log(p"/var/log/dhcp-eth0/current", 40)?,
    ],
  }
}

proc run_argv(header: Record, scoped: Bool) [env, fs, process, error] -> Result[Record, Error] {
  let argv = json.get(header, ["argv"], []).require(List[Str])?
  guard ! argv.is_empty() and ! argv[0].is_empty() else {
    return Err(refuse("argv", "argv must name an executable"))
  }
  let timeout_ms = json.get(header, ["timeout_ms"], 30000).require(Int)?
  guard timeout_ms > 0 and timeout_ms <= run_timeout_limit_ms else {
    return Err(refuse("timeout", "timeout_ms is out of range"))
  }
  var overlay: Map[Str] = {}
  var dir = fs.cwd()?
  if scoped {
    let entries = json.get(header, ["env"], {}).require(Record)?
    for name in entries.keys() {
      guard ! name.is_empty() and "=" not in name and "\u{0}" not in name else {
        return Err(refuse("env", "invalid environment name"))
      }
      let value = json.get(entries, [name], null).require(Str)?
      guard "\u{0}" not in value else {
        return Err(refuse("env", "invalid environment value"))
      }
      overlay = overlay.set(name, value)
    }
    let requested: Str? = json.get(header, ["cwd"], null).require()?
    if requested != null {
      guard requested.starts_with("/") and "\u{0}" not in requested else {
        return Err(refuse("cwd", "cwd must be an absolute directory"))
      }
      dir = fp"{requested}"
      guard dir.exists() and dir.is_dir() else {
        return Err(refuse("cwd", "cwd must be an existing directory"))
      }
    }
  }
  let result = cd (dir) {
    env (overlay) {
      run.capture --bytes --timeout=time.millis(timeout_ms) @argv
    }?
  }?
  let {stdout, stderr, ..} = result
  {
    exit_code: if result.status.exited() { result.status.exit_code()? } else { -1 },
    signaled: ! result.status.exited(),
    stdout_b64: stdout.slice(0, run_output_limit).base64(),
    stderr_b64: stderr.slice(0, run_output_limit).base64(),
    truncated: stdout.len() > run_output_limit or stderr.len() > run_output_limit,
  }
}

proc staging_root() [env, fs, error] -> Result[Path, Error] {
  let home = e"HOME"?
  guard home.starts_with("/") and ".." not in home else {
    return Err(refuse("home", "HOME is not an absolute path"))
  }
  fp"{home}/staging"
}

proc validated_name(header: Record) [error] -> Result[Str, Error] {
  let name = json.get(header, ["name"], "").require(Str)?
  guard name_re.matches(name) else {
    return Err(refuse("name", "name is not a plain file name"))
  }
  name
}

proc incoming_names(root: Path) [fs, error] -> Result[List[Str], Error] {
  return [] unless root.exists()
  let names = collect {
    for entry in fs.children(root)? {
      yield entry.name when entry.name.starts_with(".incoming-")
    }
  }
  names
}

proc staged_state(header: Record) [env, fs, error] -> Result[Record, Error] {
  let root = staging_root()?
  let target = fp"{root}/{validated_name(header)?}"
  let incoming = incoming_names(root)?
  return {present: false, size: 0, sha256: "", incoming: incoming} unless target.exists()
  {present: true, size: target.metadata()?.size, sha256: hash.sha256(target)?.hex(), incoming: incoming}
}

proc stage(header: Record) [env, fs, io, error] -> Result[Record, Error] {
  let name = validated_name(header)?
  let size = json.get(header, ["size"], -1).require(Int)?
  let sha256 = json.get(header, ["sha256"], "").require(Str)?
  guard size >= 0 and size <= stage_limit else {
    return Err(refuse("size", "size is out of range"))
  }
  guard sha256.byte_len() == 64 else {
    return Err(refuse("sha256", "sha256 must be 64 hexadecimal digits"))
  }
  let root = staging_root()?
  root.mkdir()
  let target = fp"{root}/{name}"
  let scratch = fp"{root}/.incoming-{name}"
  scratch.remove()
  var received = 0
  let _ = bytes.write_at(scratch, 0, bytes.zero(0)?, create: true)?
  while received < size {
    let want = if size - received < chunk { size - received } else { chunk }
    let data = io.stdin_read(want)?
    if data.is_empty() {
      scratch.remove()
      return Err(refuse("short-payload", f"payload ended after {received} of {size} bytes"))
    }
    let _ = bytes.write_at(scratch, received, data)?
    received += data.len()
  }
  if ! io.stdin_read(1)?.is_empty() {
    scratch.remove()
    return Err(refuse("long-payload", "payload is longer than size"))
  }
  fs.fsync(scratch)
  let actual = hash.sha256(scratch)?.hex()
  if actual != sha256.lower() {
    scratch.remove()
    return Err(refuse("digest-mismatch", f"payload digest is {actual}"))
  }
  if target.exists() {
    scratch.remove()
    if hash.sha256(target)?.hex() == actual {
      return {outcome: "present", path: target.display(), size: size, sha256: actual}
    }
    return Err(refuse("exists", "a different file already has this name"))
  }
  fs.rename_noreplace(scratch, target)
  fs.fsync(root)
  {outcome: "staged", path: target.display(), size: size, sha256: actual}
}

proc reply_ok(result: Any) [io, error] {
  io.write_stdout(json.encode({protocol: protocol, ok: true, result: result})? + "\n")
  io.flush_stdout()
}

proc reply_error(kind: Str, message: Str) [io, error] {
  io.write_stdout(json.encode({protocol: protocol, ok: false, error: {kind: kind, message: message}})? + "\n")
  io.flush_stdout()
}

proc main() [env, fs, io, process, error] {
  let header = read_header() ?? {
    reply_error("request", .message)
    return
  }
  let op = json.get(header, ["op"], "").require(Str)?
  let outcome = match op {
    "inspect" => inspect(),
    "diagnose" => diagnose(),
    "run" => run_argv(header, false),
    "run-scoped" => run_argv(header, true),
    "stage" => stage(header),
    "staged" => staged_state(header),
    else => Err(refuse("unknown-op", f"unknown operation {op}")),
  }
  match outcome {
    Ok(result) => reply_ok(result)?,
    Err(error) => {
      if let RemoteError.Refused {kind, message} = error {
        if kind == "env" or kind == "cwd" { reply_error(kind, message)? } else { reply_error("failed", message)? }
      } else {
        reply_error("failed", error.message)?
      }
    },
  }
}

main()
