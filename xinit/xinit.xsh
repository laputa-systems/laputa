#!/bin/xsh --
error XinitError = Failed(kind: Str, message: Str)

type InittabEntry = {key: Str, id: Str, action: Str, command: Str, argv: List[Str]}

type RuntimeEntry = {key: Str, pid: Int, launches: Int, next_ms: Int, action: Str}

type Service = {
  name: Str,
  path: Path,
  kind: Str,
  command: Command,
  restart_mode: Str,
  targets: List[Str],
  need: List[Str],
  uses: List[Str],
  after: List[Str],
  before: List[Str],
  delay_ms: Int,
  max_delay_ms: Int,
  stable_after_ms: Int,
  stop_timeout_ms: Int,
  log: Str,
  log_max_size: Int,
  log_keep: Int,
  cpu_max: Int,
  ready_timeout_ms: Int,
  readiness: Str,
}

type ServiceIdentity = {name: Str}

type LogPolicy = {mode: Str}

type ServiceFile = module {
  export let service: Record
  export optional proc start() [fs, process, env, error] -> Result[Unit, Error]
  export optional proc stop() [fs, process, env, time, error] -> Result[Unit, Error]
  export optional proc reload() [fs, process, env, error] -> Result[Unit, Error]
  export optional proc finish() [fs, process, env, error] -> Result[Unit, Error]
  export optional proc ready() [fs, process, env, time, error] -> Result[Bool, Error]
  export optional proc status() [fs, process, env, error] -> Result[Str, Error]
}

type DeadMark = {runtime: List[RuntimeEntry], event: Str}

type InittabPolicy = {delay_ms: UInt, launch_limit: UInt}
type InitArguments = {command: Str, action: Str, args: List[Str]}

type StartPlan = {done: List[Str], out: List[Str]}

type SavedStatus = {
  name: Str,
  desired: Str,
  state: Str,
  pid: Int,
  supervisor_pid: Int,
  log: Str,
  restarts: Int,
  ready: Bool,
  cgroup_path: Str,
  start_time_ms: Int,
}

type SpawnResult = {status: SavedStatus, notify_fd: Int}

type ChildExit = {pid: Int, status: Status}

type ServiceUnit = {
  service: Service,
  desired: Str,
  state: Str,
  pid: Int,
  restarts: Int,
  ready: Bool,
  cgroup_path: Str,
  next_ms: Int,
  current_delay: Int,
  started_at: Int,
  notify_fd: Int,
}

pure usage_text() -> Str {
  """xinit 0.0.1

Usage:
  xinit [INITTAB] [--respawn-delay-ms N] [--launch-limit N]
  xinit boot [TARGET]
  xinit scan [SERVICE|TARGET]
  xinit <start|up|stop|down|restart|reload|status|logs|supervise> SERVICE
  xinit <list|graph> [SERVICE|TARGET]
  xinit check [SERVICE|PATH]
  xinit inspect SERVICE
  xinit start-plan SERVICE
"""
}

proc env_value(name: Str, fallback: Str) -> Str {
  if let Ok(value) = env.get(name) {
    guard value.trim() == "" else {
      return value
    }
  }

  fallback
}

proc env_enabled(name: Str) -> Bool {
  let value = env_value(name, "")
  value == "1" or value == "true" or value == "yes" or value == "on"
}

proc env_int(name: Str, fallback: Int) -> Result[Int] {
  let value = env_value(name, "")

  return fallback when value == ""

  value as Int
}

pure clock_millis(nanoseconds: UInt) -> Int {
  nanoseconds / 1000000
}

proc elapsed_now_ms() -> Result[Int] {
  clock_millis(time.monotonic()?.require()?)
}

proc test_mode() -> Result[Bool] {
  env_enabled("XINIT_TEST_ALLOW_NON_PID1") and process.current_pid()? != 1
}

proc test_flag(name: Str) -> Result[Bool] {
  test_mode()? and env_enabled(name)
}

proc fake_pids() -> Result[Bool] {
  test_flag("XINIT_TEST_FAKE_PIDS")?
}

proc inittab_policy(parsed: Record) -> Result[InittabPolicy] {
  {
    delay_ms: parsed.get("respawn_delay_ms")?.require()?,
    launch_limit: parsed.get("launch_limit")?.require()?,
  }
}

proc service_dir() [env, error] -> Result[Path] {
  fp"{env_value("XINIT_SERVICE_DIR", "/usr/lib/xinit/services")}"
}

proc run_dir() [env, error] -> Result[Path] {
  fp"{env_value("XINIT_RUN_DIR", "/run/xinit")}"
}

proc log_root() [env, error] -> Result[Path] {
  fp"{env_value("XINIT_LOG_ROOT", "/var/log")}"
}

proc inbox_dir() -> Result[Path] {
  fp"{run_dir()?.display()}/inbox"
}

proc scanner_marker_path() -> Result[Path] {
  fp"{run_dir()?.display()}/scanner.json"
}

pure command_from_argv(argv: List[Str]) -> Command {
  process.command_argv(argv[0], argv)
}

pure entry_spawns(entry: InittabEntry) -> Bool {
  entry.action == "once" or entry.action == "respawn" or entry.action == "poweroff"
}

proc parse_inittab_line(line: Str, index: Int) [process, error] -> Result[InittabEntry] {
  let trimmed = line.split("#")[0].trim()

  return {key: "", id: "", action: "", command: "", argv: [""]} when trimmed == ""

  let fields = trimmed.split(":")

  if fields.len() < 2 {
    return Err(XinitError.Failed(kind: "init-inittab", message: f"line {index}: missing runlevels"))
  }

  if fields.len() < 3 {
    return Err(XinitError.Failed(kind: "init-inittab", message: f"line {index}: missing action"))
  }

  if fields.len() < 4 {
    return Err(XinitError.Failed(kind: "init-inittab", message: f"line {index}: missing command"))
  }

  let action = fields[2].trim()

  if ! (action == "sysinit" or action == "wait" or action == "once" or action == "restart" or action == "shutdown" or action == "respawn" or action == "poweroff") {
    return Err(XinitError.Failed(kind: "init-inittab", message: f"line {index}: unsupported action '{action}'"))
  }

  let command = fields |> drop(3).join(":").trim()

  if command == "" {
    return Err(XinitError.Failed(kind: "init-inittab", message: f"line {index}: missing command"))
  }

  let argv = process.argv_words(command)?

  if argv.is_empty() or argv[0] == "" {
    return Err(XinitError.Failed(kind: "init-inittab", message: f"line {index}: missing command"))
  }

  {key: f"{index}:{fields[0].trim()}", id: fields[0].trim(), action, command, argv}
}

proc parse_inittab(path_value: Path) -> Result[List[InittabEntry]] {
  var index = 1

  let entries: List[InittabEntry] = collect {
    for line in path_value.lines()? {
      let entry = parse_inittab_line(line, index)?

      yield entry when entry.action != ""

      index += 1
    }
  }

  entries
}

proc run_phase(entries: List[InittabEntry], action: Str) {
  for entry in entries {
    if entry.action == action {
      let status = process.run(command_from_argv(entry.argv))?

      return Err(XinitError.Failed(kind: "init-entry-failed", message: entry.command)) unless status.ok
    }
  }
}

pure runtime_get(runtime: List[RuntimeEntry], key: Str) -> RuntimeEntry {
  for item in runtime {
    return item when item.key == key
  }

  {key, pid: -1, launches: 0, next_ms: 0, action: ""}
}

proc runtime_set(runtime: List[RuntimeEntry], value: RuntimeEntry) [error] -> List[RuntimeEntry] {
  var found = false

  let out: List[RuntimeEntry] = collect {
    for item in runtime {
      if item.key == value.key {
        yield value
        found = true
      } else {
        yield item
      }
    }

    yield value unless found
  }

  out
}

pure spawn_due(pid: Int, now: Int, next_ms: Int) -> Bool {
  pid <= 0 and now >= next_ms
}

proc spawn_entries(
  entries: List[InittabEntry],
  runtime: List[RuntimeEntry],
  policy: InittabPolicy,
) -> Result[List[RuntimeEntry]] {
  var out = runtime
  let now = elapsed_now_ms()?

  for entry in entries {
    if entry_spawns(entry) {
      let current = runtime_get(out, entry.key)

      let launch_allowed = if entry.action == "respawn" {
        policy.launch_limit == 0 or current.launches < policy.launch_limit
      } else {
        current.launches == 0
      }

      if spawn_due(current.pid, now, current.next_ms) and launch_allowed {
        let command = command_from_argv(entry.argv)

        let child = if entry.id == "" {
          unix.spawn_process_group(command)?
        } else {
          unix.spawn_with_tty(command, tty: entry.id)?
        }

        out = runtime_set(
          out,
          {
            key: entry.key,
            pid: child.pid,
            launches: current.launches + 1,
            next_ms: now + policy.delay_ms,
            action: entry.action,
          },
        )
      }
    }
  }

  out
}

proc mark_dead(entries: List[InittabEntry], runtime: List[RuntimeEntry], pid: Int) -> DeadMark {
  var out = runtime
  var event = ""

  for entry in entries {
    if entry_spawns(entry) {
      let current = runtime_get(out, entry.key)

      if current.pid == pid {
        out = runtime_set(
          out,
          {key: entry.key, pid: -1, launches: current.launches, next_ms: current.next_ms, action: entry.action},
        )

        if entry.action == "poweroff" {
          event = "poweroff"
        }
      }
    }
  }

  {runtime: out, event}
}

pure should_exit_idle(
  entries: List[InittabEntry],
  runtime: List[RuntimeEntry],
  exit_when_idle: Bool,
  launch_limit: Int,
) -> Bool {
  guard exit_when_idle else {
    return false
  }

  for entry in entries {
    if entry.action == "respawn" {
      let current = runtime_get(runtime, entry.key)

      return false when current.pid > 0

      return false when launch_limit == 0 or current.launches < launch_limit
    }
  }

  true
}

proc shutdown_runtime(entries: List[InittabEntry], runtime: List[RuntimeEntry], fast: Bool) {
  let groups = collect {
    for entry in entries {
      if entry_spawns(entry) {
        let current = runtime_get(runtime, entry.key)

        yield current.pid when current.pid > 0
      }
    }
  }

  if ! groups.is_empty() {
    let timeout = if fast { 0ms } else { 2s }
    let _ = unix.shutdown_process_groups(groups, timeout)?
  }
}

proc finalize(kind: Str) {
  let action_log = if test_mode() { env_value("XINIT_TEST_ACTION_LOG", "") } else { "" }

  if action_log != "" {
    fp"{action_log}".write(f"""{kind}
""")

    return
  }

  if ! test_flag("XINIT_TEST_SKIP_FINAL_CLEANUP") {
    linux.kill_all(signal: "TERM", except_pid1: true)
    time.sleep(2s)
    linux.kill_all(signal: "KILL", except_pid1: true)
  }

  if kind == "halt" {
    linux.halt()
  } else if kind == "poweroff" {
    linux.poweroff()
  } else if kind == "reboot" {
    linux.reboot()
  }
}

proc run_pid1(inittab: Path, policy: InittabPolicy) {
  let allow = test_mode()?
  unix.pid1_setup(["HUP", "TERM", "USR1", "USR2", "INT"], subreaper: true, allow_non_pid1: allow)
  let entries = parse_inittab(inittab)?
  let exit_when_idle = test_flag("XINIT_TEST_EXIT_WHEN_IDLE")?
  let fast = test_flag("XINIT_TEST_FAST_SHUTDOWN")?
  var runtime: List[RuntimeEntry] = []
  var event = ""
  run_phase(entries, "sysinit")
  run_phase(entries, "wait")
  runtime = spawn_entries(entries, runtime, policy)?

  return when should_exit_idle(entries, runtime, exit_when_idle, policy.launch_limit)

  while event == "" {
    let pid_event = unix.wait_pid1_event()?

    if pid_event.kind == "signal" {
      if pid_event.signal == "HUP" {
        event = "restart"
      } else if pid_event.signal == "USR1" {
        event = "halt"
      } else if pid_event.signal == "USR2" or pid_event.signal == "INT" {
        event = "poweroff"
      } else if pid_event.signal == "TERM" {
        event = "reboot"
      }
    } else if pid_event.kind == "children" {
      for child in pid_event.children {
        let marked = mark_dead(entries, runtime, child.pid)
        runtime = marked.runtime

        if marked.event != "" {
          event = marked.event
        }
      }
    }

    if event == "" {
      runtime = spawn_entries(entries, runtime, policy)?

      return when should_exit_idle(entries, runtime, exit_when_idle, policy.launch_limit)
    }
  }

  shutdown_runtime(entries, runtime, fast)

  if event == "restart" {
    for entry in entries {
      if entry.action == "restart" {
        unix.exec(command_from_argv(entry.argv))
      }
    }

    return
  }

  run_phase(entries, "shutdown")
  finalize(event)
}

proc service_path(target: Str) -> Result[Path] {
  return fp"{target}" when "/" in target or target.ends_with(".xsh")

  fp"{service_dir()?.display()}/{target}.xsh"
}

pure builtin_facilities() -> List[Str] {
  ["logger", "net", "dns", "firewall"]
}

proc require_service_file(path_value: Path) {
  guard path_value.exists() else {
    return Err(
      XinitError.Failed(
        kind: "xinit-service",
        message: f"failed to read service file '{path_value}': No such file or directory",
      ),
    )
  }
}

pure field_context(source: Path, field: Str) -> Str {
  f"{source}: field `{field}`"
}

proc field_str(raw: Record, field: Str, fallback: Str, source: Path, scope = "") -> Result[Str] {
  return fallback when field not in raw

  raw.get(field)?.require(Str).context("xinit-service", field_context(source, if scope == "" { field } else { f"{scope}.{field}" }))?
}

proc field_int(raw: Record, field: Str, fallback: Int, source: Path, scope = "") -> Result[Int] {
  return fallback when field not in raw

  raw.get(field)?.require(Int).context("xinit-service", field_context(source, if scope == "" { field } else { f"{scope}.{field}" }))?
}

proc field_str_list(raw: Record, field: Str, source: Path, scope = "") -> Result[List[Str]] {
  return [] when field not in raw

  raw.get(field)?.require(List[Str]).context("xinit-service", field_context(source, if scope == "" { field } else { f"{scope}.{field}" }))?
}

proc field_record(raw: Record, field: Str, source: Path, scope = "") -> Result[Record] {
  if field not in raw {
    let empty: Record = {}
    return empty
  }

  raw.get(field)?.require(Record).context("xinit-service", field_context(source, if scope == "" { field } else { f"{scope}.{field}" }))?
}

proc service_field_error(source: Path, field: Str, message: Str) [error] {
  Err(XinitError.Failed(kind: "xinit-service", message: f"{field_context(source, field)}: {message}"))
}

proc check_service_fields(raw: Record, fields: List[Str], source: Path, scope = "") {
  for field in raw.keys() {
    if field not in fields {
      service_field_error(source, if scope == "" { field } else { f"{scope}.{field}" }, "unknown field")
    }
  }
}

proc check_service_name(value: Str, source: Path, field: Str) {
  let pattern = rx"^[A-Za-z0-9][A-Za-z0-9_.-]*$"

  if ! pattern.matches(value) {
    service_field_error(source, field, "must match [A-Za-z0-9][A-Za-z0-9_.-]*")
  }
}

proc check_service_names(values: List[Str], source: Path, field: Str) {
  var seen = []

  for value in values {
    check_service_name(value, source, field)

    if value in seen {
      service_field_error(source, field, f"duplicate name '{value}'")
    }

    seen += [value]
  }
}

proc check_service_values(service: Service) {
  let source = service.path
  check_service_name(service.name, source, "name")

  if service.kind not in ["longrun", "oneshot", "scripted"] {
    service_field_error(source, "kind", "must be longrun, oneshot, or scripted")
  }

  if service.restart_mode not in ["always", "on_failure", "never"] {
    service_field_error(source, "restart.mode", "must be always, on_failure, or never")
  }

  if service.readiness not in ["auto", "notify"] or (service.readiness == "notify" and service.kind != "longrun") {
    service_field_error(source, "readiness", "must be auto, or notify for a longrun")
  }

  for range in [
    {field: "restart.delay_ms", value: service.delay_ms},
    {field: "restart.max_delay_ms", value: service.max_delay_ms},
    {field: "restart.stable_after_ms", value: service.stable_after_ms},
    {field: "ready_timeout_ms", value: service.ready_timeout_ms},
    {field: "stop_timeout_ms", value: service.stop_timeout_ms},
    {field: "log.max_size", value: service.log_max_size},
    {field: "log.keep", value: service.log_keep},
    {field: "resources.cpu_max", value: service.cpu_max},
  ] {
    if range.value < 0 {
      service_field_error(source, range.field, "must be nonnegative")
    }
  }

  if service.max_delay_ms > 0 and service.max_delay_ms < service.delay_ms {
    service_field_error(source, "restart.max_delay_ms", "must be zero or at least restart.delay_ms")
  }

  check_service_names(service.targets, source, "targets")

  for edge in [
    {field: "dependencies.need", names: service.need},
    {field: "dependencies.uses", names: service.uses},
    {field: "dependencies.after", names: service.after},
    {field: "dependencies.before", names: service.before},
  ] {
    check_service_names(edge.names, source, edge.field)

    if service.name in edge.names {
      service_field_error(source, edge.field, "service cannot depend on itself")
    }
  }

  for dep in service.uses {
    if dep in service.need {
      service_field_error(source, "dependencies.uses", f"'{dep}' is already required by dependencies.need")
    }
  }
}

proc service_from_record(path_value: Path, raw: Record) [process, error] -> Result[Service] {
  check_service_fields(raw, ["name", "command", "kind", "targets", "dependencies", "restart", "readiness", "ready_timeout_ms", "stop_timeout_ms", "logging", "log", "resources"], path_value)
  let identity = raw.require(ServiceIdentity).context("xinit-service", field_context(path_value, "name"))?
  let kind = field_str(raw, "kind", "longrun", path_value)?

  if "command" not in raw {
    service_field_error(path_value, "command", "required field is missing")
  }

  let command = raw.get("command")?.require(Command).context("xinit-service", field_context(path_value, "command"))?

  let restart = field_record(raw, "restart", path_value)?
  check_service_fields(restart, ["mode", "delay_ms", "max_delay_ms", "stable_after_ms"], path_value, scope: "restart")
  let restart_mode = field_str(restart, "mode", if kind == "longrun" { "on_failure" } else { "never" }, path_value, scope: "restart")?
  let delay_ms = field_int(restart, "delay_ms", 1000, path_value, scope: "restart")?
  let max_delay_ms = field_int(restart, "max_delay_ms", 30000, path_value, scope: "restart")?
  let stable_after_ms = field_int(restart, "stable_after_ms", 10000, path_value, scope: "restart")?
  if "logging" in raw and "log" in raw {
    service_field_error(path_value, "logging", "conflicts with log")
  }

  let logging = field_str(raw, "logging", "", path_value)?
  let log = field_record(raw, "log", path_value)?
  check_service_fields(log, ["mode", "max_size", "keep"], path_value, scope: "log")
  var log_mode = "append"

  var log_max_size = 1048576
  var log_keep = 3

  if "logging" in raw {
    log_mode = logging
  } else if "log" in raw {
    log_mode = log.require(LogPolicy).context("xinit-service", field_context(path_value, "log.mode"))?.mode

    log_max_size = field_int(log, "max_size", log_max_size, path_value, scope: "log")?
    log_keep = field_int(log, "keep", log_keep, path_value, scope: "log")?
  }

  if log_mode not in ["append", "off"] {
    service_field_error(path_value, if "logging" in raw { "logging" } else { "log.mode" }, "must be append or off")
  }

  if log_mode == "off" {
    log_mode = "none"
  }

  let targets = field_str_list(raw, "targets", path_value)?
  let deps = field_record(raw, "dependencies", path_value)?
  check_service_fields(deps, ["need", "uses", "after", "before"], path_value, scope: "dependencies")
  let need = field_str_list(deps, "need", path_value, scope: "dependencies")?
  let uses = field_str_list(deps, "uses", path_value, scope: "dependencies")?
  let after = field_str_list(deps, "after", path_value, scope: "dependencies")?
  let before = field_str_list(deps, "before", path_value, scope: "dependencies")?
  let resources = field_record(raw, "resources", path_value)?
  check_service_fields(resources, ["cpu_max"], path_value, scope: "resources")
  let cpu_max = field_int(resources, "cpu_max", 0, path_value, scope: "resources")?
  let ready_timeout_ms = field_int(raw, "ready_timeout_ms", 5000, path_value)?
  let stop_timeout_ms = field_int(raw, "stop_timeout_ms", 200, path_value)?
  let readiness = field_str(raw, "readiness", "auto", path_value)?

  let service: Service = Service(
    name: identity.name,
    path: path_value,
    kind:,
    command:,
    restart_mode:,
    targets:,
    need:,
    uses:,
    after:,
    before:,
    delay_ms:,
    max_delay_ms:,
    stable_after_ms:,
    stop_timeout_ms:,
    log: log_mode,
    log_max_size:,
    log_keep:,
    cpu_max:,
    ready_timeout_ms:,
    readiness:,
  )

  check_service_values(service)
  service
}

proc load_service_path(path_value: Path) [fs, process, env, error] -> Result[Service] {
  require_service_file(path_value)
  let loaded = module.load(path_value)?.require(ServiceFile)?
  service_from_record(path_value, loaded.service)?
}

proc load_service(target: Str) -> Result[Service] {
  let path_value = service_path(target)?
  let service = load_service_path(path_value)?

  return service when "/" in target or target.ends_with(".xsh") or service.name == target

  Err(
    XinitError.Failed(
      kind: "xinit-service",
      message: f"service file '{path_value}' defines '{service.name}', not '{target}'",
    ),
  )
}

proc all_services() -> Result[List[Service]] {
  let dir = service_dir()?

  return [] unless dir.exists()

  [load_service_path(entry.path)? for entry in fs.children(dir)?
    |> where .kind == "file" and .name.ends_with(".xsh")
    |> sort-by .name]
}

pure service_names(services: List[Service]) -> List[Str] {
  [service.name for service in services]
}

pure contains_name(services: List[Service], name: Str) -> Bool {
  for service in services {
    return true when service.name == name
  }

  false
}

pure find_loaded_service(services: List[Service], name: Str) -> Result[Service] {
  for service in services {
    return service when service.name == name
  }

  Err(XinitError.Failed(kind: "xinit-service", message: f"unknown service '{name}'"))
}

pure required_dependencies(service: Service) -> List[Str] {
  service.need.extend(service.uses)
}

pure dependency_edges(service: Service) -> List[Str] {
  [@service.need, @service.uses, @service.after]
}

proc check_service_graph(services: List[Service]) {
  let names = service_names(services)
  let facilities = builtin_facilities()

  var seen = []

  for service in services {
    if service.name in seen {
      service_field_error(service.path, "name", f"duplicate service name '{service.name}'")
    }

    seen += [service.name]

    for dep in dependency_edges(service).extend(service.before) {
      if dep not in names and dep not in facilities {
        return Err(XinitError.Failed(kind: "xinit-deps", message: f"{field_context(service.path, "dependencies")}: unknown dependency '{dep}'"))
      }
    }
  }

  for service in services {
    let _ = visit_plan(services, service.name, [], [], []).context("xinit-deps", field_context(service.path, "dependencies"))?
  }
}

pure visit_plan(
  services: List[Service],
  name: Str,
  stack: List[Str],
  done: List[Str],
  out: List[Str],
) -> Result[StartPlan] {
  return {done, out} when name in done

  if name in stack {
    return Err(XinitError.Failed(kind: "xinit-deps", message: f"dependency cycle: {stack.push(name).join(" -> ")}"))
  }

  let service = find_loaded_service(services, name)?
  var next_done = done
  var next_out = out

  for dep in dependency_edges(service) {
    if contains_name(services, dep) {
      let planned = visit_plan(services, dep, stack.push(name), next_done, next_out)?
      next_done = planned.done
      next_out = planned.out
    }
  }

  for candidate in services {
    if name in candidate.before {
      let planned = visit_plan(services, candidate.name, stack.push(name), next_done, next_out)?
      next_done = planned.done
      next_out = planned.out
    }
  }

  next_done += [name]
  next_out += [name]
  {done: next_done, out: next_out}
}

pure required_closure(services: List[Service], name: Str, out: List[Str]) -> Result[List[Str]] {
  return out when name in out

  var next = out.push(name)
  let service = find_loaded_service(services, name)?

  for dep in service.need {
    if contains_name(services, dep) {
      next = required_closure(services, dep, next)?
    }
  }

  next
}

proc required_names(name: Str) -> Result[List[Str]] {
  var services = all_services()?

  if ! contains_name(services, name) {
    services += [load_service(name)?]
  }

  required_closure(services, name, [])?
}

proc plan_service_start(name: Str) -> Result[List[Str]] {
  var services = all_services()?

  if ! contains_name(services, name) {
    services += [load_service(name)?]
  }

  check_service_graph(services)
  let planned = visit_plan(services, name, [], [], [])?
  planned.out
}

proc plan_target_start(target: Str) -> Result[List[Str]] {
  let services = all_services()?
  check_service_graph(services)
  var out = []
  var done = []

  for service in services {
    if target in service.targets {
      let planned = visit_plan(services, service.name, [], done, out)?
      done = planned.done
      out = planned.out
    }
  }

  out
}

proc state_path(name: Str) -> Result[Path] {
  fp"{run_dir()?.display()}/{name}.json"
}

pure default_status(name: Str) -> SavedStatus {
  {
    name,
    desired: "down",
    state: "down",
    pid: 0,
    supervisor_pid: 0,
    log: "append",
    restarts: 0,
    ready: false,
    cgroup_path: "",
    start_time_ms: 0,
  }
}

proc pid_alive(pid: Int) -> Bool {
  guard pid > 0 else {
    return false
  }

  match process.kill(pid, "0") {
    Ok(_) => true
    Err(_) => false
  }
}

proc pid_start_time(pid: Int) -> Result[Int] {
  guard pid > 0 else {
    return 0
  }

  for entry in process.list()? {
    return entry.start_time_ms when entry.pid == pid
  }

  0
}

proc pid_live_and_ours(pid: Int, start_time_ms: Int) -> Result[Bool] {
  guard pid_alive(pid) else {
    return false
  }

  return true when start_time_ms <= 0

  pid_start_time(pid)? == start_time_ms
}

proc read_status(name: Str) -> Result[SavedStatus] {
  let path_value = state_path(name)?

  return default_status(name) unless path_value.exists()

  let raw = json.read(path_value)?
  let status_name = json.get(raw, ["name"], name).require(Str)?
  let desired = json.get(raw, ["desired"], "down").require(Str)?
  let state = json.get(raw, ["state"], "down").require(Str)?
  let pid = json.get(raw, ["pid"], 0).require(Int)?
  let supervisor_pid = json.get(raw, ["supervisor_pid"], 0).require(Int)?
  let log = json.get(raw, ["log"], "append").require(Str)?
  let restarts = json.get(raw, ["restarts"], 0).require(Int)?
  let ready = json.get(raw, ["ready"], state == "running").require(Bool)?
  let cgroup_path = json.get(raw, ["cgroup_path"], "").require(Str)?
  let start_time_ms = json.get(raw, ["start_time_ms"], 0).require(Int)?

  let status: SavedStatus = SavedStatus(
    name: status_name,
    desired:,
    state:,
    pid:,
    supervisor_pid:,
    log:,
    restarts:,
    ready:,
    cgroup_path:,
    start_time_ms:,
  )

  if status.state == "running" and status.pid > 0 and ! fake_pids() and ! pid_live_and_ours(
    status.pid,
    status.start_time_ms,
  ) {
    return {
      name: status.name,
      desired: status.desired,
      state: "dead",
      pid: 0,
      supervisor_pid: status.supervisor_pid,
      log: status.log,
      restarts: status.restarts,
      ready: false,
      cgroup_path: status.cgroup_path,
      start_time_ms: 0,
    }
  }

  status
}

proc write_status(status: SavedStatus) [fs, process, env, error] {
  let dir = run_dir()?
  dir.mkdir()
  json.write(state_path(status.name)?, status)
}

proc status_line(status: SavedStatus) [error] -> Str {
  var line = f"{status.name} {status.state} pid={status.pid} ready={status.ready} log={status.log} desired={status.desired} restarts={status.restarts}"

  if status.supervisor_pid > 0 {
    line = f"{line} supervisor={status.supervisor_pid}"
  }

  if status.cgroup_path != "" {
    line = f"{line} cgroup={status.cgroup_path}"
  }

  line
}

proc log_path(name: Str) -> Result[Path] {
  fp"{log_root()?.display()}/{name}/current"
}

proc rotated_log_path(current: Path, index: Int) [error] -> Result[Path] {
  fp"{current}.{index}"
}

proc rotate_log(name: Str, keep: Int) {
  let current = log_path(name)?
  rotated_log_path(current, keep)?.remove(missing_ok: true)
  var index = keep - 1

  while index >= 1 {
    let older = rotated_log_path(current, index)?

    if older.exists() {
      older.rename(to: rotated_log_path(current, index + 1)?, overwrite: true)
    }

    index -= 1
  }

  current.copy(to: rotated_log_path(current, 1)?, overwrite: true)
  current.truncate(0)
}

proc maybe_rotate_log(name: Str, max_size: Int, keep: Int) {
  return when max_size <= 0 or keep <= 0

  let current = log_path(name)?

  return unless current.exists()

  if current.metadata()?.size >= max_size {
    rotate_log(name, keep)
  }
}

proc wait_ready(service: Service) -> Result[Bool] {
  require_service_file(service.path)
  let loaded = module.load(service.path)?.require(ServiceFile)?

  return true when "ready" not in loaded.keys()

  let deadline = elapsed_now_ms()? + service.ready_timeout_ms

  while elapsed_now_ms()? <= deadline {
    return true when loaded.ready()

    time.sleep(100ms)
  }

  false
}

proc run_start_proc(service: Service) -> Result[Bool] {
  require_service_file(service.path)
  let loaded = module.load(service.path)?.require(ServiceFile)?

  if "start" in loaded.keys() {
    loaded.start()
    return true
  }

  false
}

proc run_stop_proc(service: Service) -> Result[Bool] {
  require_service_file(service.path)
  let loaded = module.load(service.path)?.require(ServiceFile)?

  if "stop" in loaded.keys() {
    loaded.stop()
    return true
  }

  false
}

proc run_reload_proc(service: Service) -> Result[Bool] {
  require_service_file(service.path)
  let loaded = module.load(service.path)?.require(ServiceFile)?

  if "reload" in loaded.keys() {
    loaded.reload()
    return true
  }

  false
}

proc reload_unit(service: Service, pid: Int) {
  if run_reload_proc(service) {} else if pid > 0 {
    unix.kill_process_group(pid, "HUP")
  }
}

proc spawn_service(service: Service, restarts: Int, notify: Bool) -> Result[SpawnResult] {
  let cgroup_path = if service.cpu_max > 0 and fake_pids() and env_value("XSH_CGROUP_ROOT", "") == "" {
    f"dry-run:/xinit/{service.name}"
  } else {
    ""
  }

  if service.kind == "oneshot" or service.kind == "scripted" {
    if ! run_start_proc(service) {
      let status = process.run(service.command)?

      if ! status.ok {
        return Err(XinitError.Failed(kind: "xinit-service", message: f"{service.name}: start failed"))
      }
    }

    return {
      status: {
        name: service.name,
        desired: "up",
        state: "running",
        pid: 0,
        supervisor_pid: 0,
        log: service.log,
        restarts,
        ready: wait_ready(service)?,
        cgroup_path,
        start_time_ms: 0,
      },
      notify_fd: -1,
    }
  }

  let use_notify = notify and service.readiness == "notify"

  if service.log == "none" {
    let child = unix.spawn_process_group(service.command, notify: use_notify)?
    let ready = if use_notify { false } else { wait_ready(service)? }

    return {
      status: {
        name: service.name,
        desired: "up",
        state: "running",
        pid: child.pid,
        supervisor_pid: 0,
        log: service.log,
        restarts,
        ready,
        cgroup_path,
        start_time_ms: 0,
      },
      notify_fd: child.notify_fd,
    }
  }

  let path_value = log_path(service.name)?

  match path_value.parent.mkdir() {
    Ok(_) => {}
    Err(err) => return Err(XinitError.Failed(kind: "xinit-log", message: err.message))
  }

  maybe_rotate_log(service.name, service.log_max_size, service.log_keep)
  let child = unix.spawn_process_group_log(service.command, path_value, notify: use_notify)?
  let ready = if use_notify { false } else { wait_ready(service)? }

  {
    status: {
      name: service.name,
      desired: "up",
      state: "running",
      pid: child.pid,
      supervisor_pid: 0,
      log: service.log,
      restarts,
      ready,
      cgroup_path,
      start_time_ms: 0,
    },
    notify_fd: child.notify_fd,
  }
}

proc start_one_service(name: Str) -> Result[SavedStatus] {
  let current = read_status(name)?

  return current when current.pid > 0 and current.state == "running"

  let service = load_service(name)?

  let spawned = spawn_service(service, current.restarts, false)?
  let base = spawned.status

  let start_time_ms = if base.pid > 0 { pid_start_time(base.pid)? } else { 0 }

  let status: SavedStatus = SavedStatus(
    name: base.name,
    desired: base.desired,
    state: base.state,
    pid: base.pid,
    supervisor_pid: base.supervisor_pid,
    log: base.log,
    restarts: base.restarts,
    ready: base.ready,
    cgroup_path: base.cgroup_path,
    start_time_ms:,
  )

  write_status(status)
  status
}

proc scanner_active() -> Result[Bool] {
  return false when fake_pids()

  let marker = scanner_marker_path()?

  return false unless marker.exists()

  let raw = json.read(marker)?
  let pid = json.get(raw, ["pid"], 0).require(Int)?
  pid_alive(pid)
}

proc request_desired(name: Str, desired: Str) [fs, process, env, error] {
  let dir = inbox_dir()?
  dir.mkdir()
  fp"{dir}/{name}".write_atomic(desired)
  print f"{name} {desired} queued"
}

proc start_service(name: Str) {
  if scanner_active() {
    request_desired(name, "up")
    return
  }

  let required = required_names(name)?
  var last = default_status(name)

  for item in plan_service_start(name)? {
    if item in required {
      last = start_one_service(item)?
    } else {
      if let Ok(status) = start_one_service(item) {
        last = status
      }
    }
  }

  print status_line(last)
}

proc running_dependents(name: Str) -> Result[List[Str]] {
  let services = all_services()?
  let out = collect {
    for service in services {
      if service.name != name and name in required_dependencies(service) {
        let status = read_status(service.name)?

        yield service.name when status.state == "running"
      }
    }
  }

  out
}

proc stop_service(name: Str) {
  if scanner_active() {
    request_desired(name, "down")
    return
  }

  let dependents = running_dependents(name)?

  if ! dependents.is_empty() {
    return Err(XinitError.Failed(kind: "xinit-deps", message: f"{name}: running dependents: {dependents.join(", ")}"))
  }

  let current = read_status(name)?
  let service = load_service(name)?

  if run_stop_proc(service) {} else if current.pid > 0 {
    unix.kill_process_group(current.pid, "TERM")
    time.sleep(time.millis(service.stop_timeout_ms))

    match unix.kill_process_group(current.pid, "KILL") {
      Ok(_) | Err(_) => {}
    }
  }

  let stopped = {
    name: current.name,
    desired: "down",
    state: "down",
    pid: 0,
    supervisor_pid: 0,
    log: current.log,
    restarts: current.restarts,
    ready: false,
    cgroup_path: "",
    start_time_ms: 0,
  }

  write_status(stopped)
  print status_line(stopped)
}

proc restart_service(name: Str) {
  if scanner_active() {
    request_desired(name, "restart")
    return
  }

  stop_service(name)
  let status = start_one_service(name)?
  print status_line(status)
}

proc reload_service(name: Str) [fs, process, env, time, error] {
  if scanner_active() {
    request_desired(name, "reload")
    return
  }

  let current = read_status(name)?
  reload_unit(load_service(name)?, current.pid)
  print status_line(current)
}

proc show_status(name: Str) {
  var current = read_status(name)?

  if let Ok(loaded) = load_service(name) {
    current = read_status(loaded.name)?
    require_service_file(loaded.path)
    let module_value = module.load(loaded.path)?.require(ServiceFile)?

    if "status" in module_value.keys() {
      let detail = module_value.status()?

      if detail != "" {
        print f"{status_line(current)} {detail}"
        return
      }
    }
  }

  print status_line(current)
}

proc show_logs(name: Str) {
  let current = log_path(name)?

  if current.exists() {
    io.write_stdout(current.read_text()?)
  }
}

proc check_service(...targets: List[Str]) {
  let services = if targets.is_empty() { all_services()? } else { [load_service(targets[0])?] }
  check_service_graph(services)
  let names = [service.name for service in services].join(" ")

  if names == "" {
    print "valid 0 services"
  } else {
    print f"valid {services.len()} service(s): {names}"
  }
}

pure escalate_delay(used_ms: Int, max_delay_ms: Int) -> Int {
  return max_delay_ms when max_delay_ms > 0 and used_ms > max_delay_ms / 2

  used_ms * 2
}

pure restart_delay(service: Service, current_delay: Int, started_at: Int, now: Int) -> Int {
  return service.delay_ms when now >= started_at and now - started_at >= service.stable_after_ms

  current_delay
}

pure unit_init(service: Service) -> ServiceUnit {
  {
    service,
    desired: "up",
    state: "pending",
    pid: 0,
    restarts: 0,
    ready: false,
    cgroup_path: "",
    next_ms: 0,
    current_delay: service.delay_ms,
    started_at: 0,
    notify_fd: -1,
  }
}

pure unit_state_label(unit: ServiceUnit) -> Str {
  return "running" when unit.state == "running"

  return "starting" when unit.state == "starting"

  return "finishing" when unit.state == "finishing"

  return "dead" when unit.state == "dead"

  "down"
}

pure unit_saved_status(unit: ServiceUnit) -> SavedStatus {
  {
    name: unit.service.name,
    desired: unit.desired,
    state: unit_state_label(unit),
    pid: if unit.pid > 0 { unit.pid } else { 0 },
    supervisor_pid: 0,
    log: unit.service.log,
    restarts: unit.restarts,
    ready: unit.state == "running" and unit.ready,
    cgroup_path: unit.cgroup_path,
    start_time_ms: 0,
  }
}

pure reverse_units(units: List[ServiceUnit]) -> List[ServiceUnit] {
  var i = units.len() - 1

  let out: List[ServiceUnit] = collect {
    while i >= 0 {
      yield units[i]
      i -= 1
    }
  }

  out
}

pure all_units_stopped(units: List[ServiceUnit]) -> Bool {
  for unit in units {
    guard unit.state == "stopped" else {
      return false
    }
  }

  true
}

proc advance_readiness(unit: ServiceUnit, now: Int) -> Result[ServiceUnit] {
  let ready = unit.notify_fd > 0 and unix.notify_ready(unit.notify_fd)?
  let timed_out = now - unit.started_at >= unit.service.ready_timeout_ms

  return unit when ! ready and ! timed_out

  if unit.notify_fd > 0 {
    unix.notify_close(unit.notify_fd)
  }

  let running: ServiceUnit = ServiceUnit(
    service: unit.service,
    desired: unit.desired,
    state: "running",
    pid: unit.pid,
    restarts: unit.restarts,
    ready:,
    cgroup_path: unit.cgroup_path,
    next_ms: unit.next_ms,
    current_delay: unit.current_delay,
    started_at: unit.started_at,
    notify_fd: -1,
  )

  write_status(unit_saved_status(running))
  running
}

pure unit_state_of(units: List[ServiceUnit], name: Str) -> Str {
  for unit in units {
    return unit.state when unit.service.name == name
  }

  ""
}

pure gate_satisfied(units: List[ServiceUnit], service: Service) -> Bool {
  for dep in service.need {
    let state = unit_state_of(units, dep)

    return false when state != "" and state != "running"
  }

  for dep in service.uses.extend(service.after) {
    let state = unit_state_of(units, dep)

    return false when state != "" and state != "running" and state != "stopped"
  }

  true
}

pure unit_blocked(units: List[ServiceUnit], unit: ServiceUnit) -> Bool {
  unit.desired == "up" and unit.state == "pending" and ! gate_satisfied(units, unit.service)
}

proc reconcile_one(unit: ServiceUnit, units: List[ServiceUnit], now: Int) -> Result[ServiceUnit] {
  return advance_readiness(unit, now)? when unit.state == "starting"

  return unit when unit.desired != "up"

  return unit when unit.state != "pending" and unit.state != "dead"

  return unit when unit.state == "pending" and ! gate_satisfied(units, unit.service)

  return unit unless spawn_due(unit.pid, now, unit.next_ms)

  let restarts = if unit.state == "dead" { unit.restarts + 1 } else { unit.restarts }
  let spawned = spawn_service(unit.service, restarts, true)?
  let state = if spawned.notify_fd > 0 { "starting" } else { "running" }

  let started: ServiceUnit = ServiceUnit(
    service: unit.service,
    desired: "up",
    state:,
    pid: spawned.status.pid,
    restarts:,
    ready: spawned.status.ready,
    cgroup_path: spawned.status.cgroup_path,
    next_ms: unit.next_ms,
    current_delay: unit.current_delay,
    started_at: now,
    notify_fd: spawned.notify_fd,
  )

  write_status(unit_saved_status(started))
  started
}

proc reconcile_all(units: List[ServiceUnit], now: Int) -> Result[List[ServiceUnit]] {
  [reconcile_one(unit, units, now)? for unit in units]
}

pure finishing_unit(unit: ServiceUnit) -> ServiceUnit {
  {
    service: unit.service,
    desired: unit.desired,
    state: "finishing",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: unit.next_ms,
    current_delay: unit.current_delay,
    started_at: unit.started_at,
    notify_fd: -1,
  }
}

proc run_finish(unit: ServiceUnit) {
  require_service_file(unit.service.path)
  let loaded = module.load(unit.service.path)?.require(ServiceFile)?

  if "finish" in loaded.keys() {
    write_status(unit_saved_status(finishing_unit(unit)))
    loaded.finish()
  }
}

proc mark_unit_dead(unit: ServiceUnit, child_status: Status, now: Int) -> Result[ServiceUnit] {
  if unit.notify_fd > 0 {
    unix.notify_close(unit.notify_fd)
  }

  run_finish(unit)

  let should_restart = unit.service.restart_mode == "always" or (unit.service.restart_mode == "on_failure" and ! child_status.exited_with(
    0,
  ))

  if ! should_restart {
    let stopped: ServiceUnit = ServiceUnit(
      service: unit.service,
      desired: "down",
      state: "stopped",
      pid: 0,
      restarts: unit.restarts,
      ready: false,
      cgroup_path: "",
      next_ms: 0,
      current_delay: unit.service.delay_ms,
      started_at: 0,
      notify_fd: -1,
    )

    write_status(unit_saved_status(stopped))
    return stopped
  }

  let delay = restart_delay(unit.service, current_delay: unit.current_delay, started_at: unit.started_at, now:)

  let dead: ServiceUnit = ServiceUnit(
    service: unit.service,
    desired: "up",
    state: "dead",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: now + delay,
    current_delay: escalate_delay(delay, unit.service.max_delay_ms),
    started_at: unit.started_at,
    notify_fd: -1,
  )

  write_status(unit_saved_status(dead))
  dead
}

proc mark_children_dead(
  units: List[ServiceUnit],
  child_pid: Int,
  child_status: Status,
  now: Int,
) -> Result[List[ServiceUnit]] {
  let out: List[ServiceUnit] = collect {
    for unit in units {
      if unit.pid > 0 and unit.pid == child_pid and (unit.state == "running" or unit.state == "starting") {
        yield mark_unit_dead(unit, child_status, now)?
      } else {
        yield unit
      }
    }
  }

  out
}

proc reconcile_child_exits(units: List[ServiceUnit], children: List[ChildExit], now: Int) -> Result[List[ServiceUnit]] {
  var out = units
  var pending = children
  var index = 0

  while index < pending.len() {
    let child = pending[index]
    index += 1

    for unit in out {
      if unit.pid > 0 and unit.pid == child.pid and (unit.state == "running" or unit.state == "starting") {
        let cleanup = unix.shutdown_process_groups([unit.pid], time.millis(unit.service.stop_timeout_ms), 100ms)?

        guard cleanup.remaining.is_empty() else {
          return Err(XinitError.Failed(kind: "xinit-cleanup", message: f"service {unit.service.name} retained process group {unit.pid}"))
        }

        pending = pending + cleanup.reaped
      }
    }

    out = mark_children_dead(out, child.pid, child.status, now)?
  }

  out
}

proc kill_unit(unit: ServiceUnit) {
  return when unit.pid <= 0 and unit.state not in ["running", "starting"]

  if unit.notify_fd > 0 {
    unix.notify_close(unit.notify_fd)
  }

  if run_stop_proc(unit.service) {} else if unit.pid > 0 {
    unix.kill_process_group(unit.pid, "TERM")
    time.sleep(time.millis(unit.service.stop_timeout_ms))

    match unix.kill_process_group(unit.pid, "KILL") {
      Ok(_) | Err(_) => {}
    }
  }

  run_finish(unit)
}

proc stop_unit(unit: ServiceUnit) -> Result[ServiceUnit] {
  kill_unit(unit)

  let stopped: ServiceUnit = ServiceUnit(
    service: unit.service,
    desired: "down",
    state: "stopped",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: 0,
    current_delay: unit.service.delay_ms,
    started_at: 0,
    notify_fd: -1,
  )

  write_status(unit_saved_status(stopped))
  stopped
}

proc shutdown_all(units: List[ServiceUnit]) -> Result[List[ServiceUnit]] {
  let reversed = [stop_unit(unit)? for unit in reverse_units(units)]
  reverse_units(reversed)
}

proc write_scanner_marker() {
  let dir = run_dir()?
  dir.mkdir()
  json.write(scanner_marker_path()?, {pid: process.current_pid()?})
}

proc apply_one(unit: ServiceUnit, name: Str, desired: Str) -> Result[ServiceUnit] {
  guard unit.service.name == name else {
    return unit
  }

  if desired == "down" {
    if unit.pid > 0 or unit.state == "running" or unit.state == "starting" {
      return stop_unit(unit)?
    }

    return {
      service: unit.service,
      desired: "down",
      state: "stopped",
      pid: 0,
      restarts: unit.restarts,
      ready: false,
      cgroup_path: "",
      next_ms: 0,
      current_delay: unit.service.delay_ms,
      started_at: 0,
      notify_fd: -1,
    }
  }

  if desired == "reload" {
    if unit.state == "running" or unit.state == "starting" {
      reload_unit(unit.service, unit.pid)
    }

    return unit
  }

  if desired == "restart" {
    kill_unit(unit)

    let restarted: ServiceUnit = ServiceUnit(
      service: unit.service,
      desired: "up",
      state: "pending",
      pid: 0,
      restarts: unit.restarts,
      ready: false,
      cgroup_path: "",
      next_ms: 0,
      current_delay: unit.service.delay_ms,
      started_at: 0,
      notify_fd: -1,
    )

    write_status(unit_saved_status(restarted))
    return restarted
  }

  return unit when unit.state == "running" or unit.state == "starting"

  {
    service: unit.service,
    desired: "up",
    state: "pending",
    pid: 0,
    restarts: unit.restarts,
    ready: false,
    cgroup_path: "",
    next_ms: 0,
    current_delay: unit.service.delay_ms,
    started_at: 0,
    notify_fd: -1,
  }
}

proc apply_request(units: List[ServiceUnit], name: Str, desired: Str) -> Result[List[ServiceUnit]] {
  [apply_one(unit, name, desired)? for unit in units]
}

proc drain_inbox(units: List[ServiceUnit]) -> Result[List[ServiceUnit]] {
  let dir = inbox_dir()?

  return units unless dir.exists()

  var out = units

  for entry in fs.children(dir)?
    |> where .kind == "file"
    |> sort-by .name {
    let desired = entry.path.read_text()?.trim()

    if desired == "up" or desired == "down" or desired == "restart" or desired == "reload" {
      out = apply_request(out, entry.name, desired)?
    }

    entry.path.remove(missing_ok: false)
  }

  out
}

pure readiness_poll_ms() -> Int {
  100
}

pure due_ms(unit: ServiceUnit, now: Int) -> Int {
  let due = unit.next_ms - now

  return 0 when due < 0

  due
}

pure next_wait_ms(units: List[ServiceUnit], now: Int) -> Int {
  var soonest = -1

  for unit in units {
    let candidate = if unit.state == "starting" {
      readiness_poll_ms()
    } else if unit.desired != "up" {
      -1
    } else if unit.state == "dead" {
      due_ms(unit, now)
    } else if unit.state == "pending" and ! unit_blocked(units, unit) {
      due_ms(unit, now)
    } else {
      -1
    }

    if candidate >= 0 and (soonest < 0 or candidate < soonest) {
      soonest = candidate
    }
  }

  return 3600000 when soonest < 0

  soonest
}

proc enforce_log_caps(units: List[ServiceUnit]) {
  for unit in units {
    if unit.state == "running" and unit.service.log == "append" {
      maybe_rotate_log(unit.service.name, unit.service.log_max_size, unit.service.log_keep)
    }
  }
}

proc scan_units(names: List[Str]) {
  unix.pid1_setup(["HUP", "TERM", "INT"], subreaper: true, allow_non_pid1: true)
  var units = [unit_init(load_service(name)?) for name in names]
  var remaining = if test_mode() { env_int("XINIT_TEST_MAX_EVENTS", -1)? } else { -1 }
  var shutting_down = false
  write_scanner_marker()

  while true {
    if ! shutting_down {
      units = drain_inbox(units)?
    }

    units = reconcile_all(units, elapsed_now_ms()?)?
    enforce_log_caps(units)

    return when shutting_down and all_units_stopped(units)

    return when remaining == 0

    let event = unix.wait_pid1_event(timeout: time.millis(next_wait_ms(units, elapsed_now_ms()?)))?

    if remaining > 0 {
      remaining -= 1
    }

    if event.kind == "signal" and (event.signal == "TERM" or event.signal == "INT") {
      let groups = [unit.pid for unit in units if unit.pid > 0]
      units = shutdown_all(units)?
      let cleanup = unix.shutdown_process_groups(groups, 0ms, 100ms)?

      guard cleanup.remaining.is_empty() else {
        return Err(XinitError.Failed(kind: "xinit-cleanup", message: "scanner retained owned process groups during shutdown"))
      }

      shutting_down = true
    } else if event.kind == "children" {
      units = reconcile_child_exits(units, event.children, elapsed_now_ms()?)?
    }
  }
}

proc supervise_service(name: Str) {
  scan_units([name])
}

proc scan_command(target: Str) {
  let names = match load_service(target) { Ok(_) => plan_service_start(target)?, Err(_) => plan_target_start(target)? }
  scan_units(names)
}

proc boot_target(target: Str) {
  var last = default_status(target)

  for item in plan_target_start(target)? {
    last = start_one_service(item)?
  }

  print status_line(last)
}

pure service_configuration(service: Service) -> Record {
  {
    name: service.name,
    source: service.path.display(),
    command: "redacted",
    kind: service.kind,
    targets: service.targets,
    dependencies: {need: service.need, uses: service.uses, after: service.after, before: service.before},
    restart: {mode: service.restart_mode, delay_ms: service.delay_ms, max_delay_ms: service.max_delay_ms, stable_after_ms: service.stable_after_ms},
    readiness: service.readiness,
    ready_timeout_ms: service.ready_timeout_ms,
    stop_timeout_ms: service.stop_timeout_ms,
    log: {mode: service.log, max_size: service.log_max_size, keep: service.log_keep},
    resources: {cpu_max: service.cpu_max},
  }
}

proc inspect_service(name: Str) {
  print json.encode(service_configuration(load_service(name)?))?
}

proc show_start_plan(name: Str) {
  let plan = [service_configuration(load_service(item)?) for item in plan_service_start(name)?]
  print json.encode(plan)?
}

proc list_services() {
  for service in all_services()? {
    let status = read_status(service.name)?
    print f"{service.name} {service.kind} targets={service.targets.join(",")} state={status.state} ready={status.ready}"
  }
}

proc graph_target(target: Str) {
  let plan = plan_target_start(target)?

  for item in plan {
    let service = load_service(item)?
    let deps = dependency_edges(service).join(",")
    print f"{item}: deps={deps}"
  }
}

proc graph_service(name: Str) {
  for item in plan_service_start(name)? {
    let service = load_service(item)?
    let deps = dependency_edges(service).join(",")
    print f"{item}: deps={deps}"
  }
}

proc control(verb: Str, name: Str) {
  if verb == "start" or verb == "up" {
    start_service(name)
  } else if verb == "stop" or verb == "down" {
    stop_service(name)
  } else if verb == "restart" {
    restart_service(name)
  } else if verb == "reload" {
    reload_service(name)
  } else if verb == "status" {
    show_status(name)
  } else if verb == "logs" {
    show_logs(name)
  } else if verb == "supervise" {
    supervise_service(name)
  } else {
    return Err(
      XinitError.Failed(
        kind: "xinit-control",
        message: "usage: xinit <start|stop|restart|reload|status|logs|supervise> SERVICE",
      ),
    )
  }
}

proc main(...argv: List[Str]) [fs, process, env, time, error, io] {
  let init_options = {
    respawn_delay_ms: {kind: "UInt", default: 1000},
    launch_limit: {kind: "UInt", default: 0},
  }
  let parsed_raw = cli.commands(
    argv,
    rootless_default: "pid1",
    commands: {
      pid1: {
        options: init_options,
        rest: "args",
      },
      help: {
        aliases: [
          "--help",
          "-h",
        ],
        rest: "args",
      },
      boot: {
        rest: "args",
      },
      scan: {
        rest: "args",
      },
      list: {
        rest: "args",
      },
      graph: {
        rest: "args",
      },
      inspect: {
        rest: "args",
      },
      "start-plan": {
        rest: "args",
      },
      start: {
        form: "start SERVICE",
        aliases: [
          "up",
        ],
        rest: "args",
      },
      stop: {
        form: "stop SERVICE",
        aliases: [
          "down",
        ],
        rest: "args",
      },
      restart: {
        form: "restart SERVICE",
        rest: "args",
      },
      reload: {
        form: "reload SERVICE",
        rest: "args",
      },
      status: {
        form: "status SERVICE",
        rest: "args",
      },
      logs: {
        form: "logs SERVICE",
        rest: "args",
      },
      supervise: {
        form: "supervise SERVICE",
        rest: "args",
      },
      check: {
        rest: "args",
      },
    },
    fallback_command: {positionals: ["inittab"], types: {inittab: "Path"}, options: init_options, rest: "args"},
  )?
  let parsed = parsed_raw.require(InitArguments)?

  if parsed.command == "pid1" {
    guard parsed.args.is_empty() else {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit"))
    }

    run_pid1(fp"{env_value("XSH_INIT_INITTAB", "/etc/inittab")}", inittab_policy(parsed_raw)?)
  } else if parsed.command == "help" {
    guard parsed.args.is_empty() else {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit help"))
    }

    io.write_stdout(usage_text())
  } else if parsed.command == "boot" {
    if parsed.args.len() > 1 {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit boot [TARGET]"))
    }

    boot_target(parsed.args.get(0) ?? "boot")
  } else if parsed.command == "scan" {
    if parsed.args.len() > 1 {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit scan [SERVICE|TARGET]"))
    }

    scan_command(parsed.args.get(0) ?? "boot")
  } else if parsed.command == "inspect" or parsed.command == "start-plan" {
    guard parsed.args.len() == 1 else {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit <inspect|start-plan> SERVICE"))
    }

    if parsed.command == "inspect" {
      inspect_service(parsed.args[0])
    } else {
      show_start_plan(parsed.args[0])
    }
  } else if parsed.command == "list" {
    guard parsed.args.is_empty() else {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit list"))
    }

    list_services()
  } else if parsed.command == "graph" {
    if parsed.args.len() > 1 {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit graph [SERVICE|TARGET]"))
    }

    let target = parsed.args.get(0) ?? "boot"
    match load_service(target) {
      Ok(_) => graph_service(target)
      Err(_) => graph_target(target)
    }
  } else if parsed.command == "start" or parsed.command == "stop" or parsed.command == "restart" or parsed.command == "reload" or parsed.command == "status" or parsed.command == "logs" or parsed.command == "supervise" {
    guard parsed.args.is_empty() else {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit <action> SERVICE"))
    }

    control(parsed.action, parsed_raw.get("service")?.require()?)
  } else if parsed.command == "check" {
    if parsed.args.len() > 1 {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit check [SERVICE|PATH]"))
    }

    if parsed.args.is_empty() {
      check_service()
    } else {
      check_service(parsed.args[0])
    }
  } else {
    guard parsed.args.is_empty() else {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit INITTAB"))
    }

    run_pid1(parsed_raw.get("inittab")?.require()?, inittab_policy(parsed_raw)?)
  }
}
