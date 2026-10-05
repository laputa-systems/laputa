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

# The one key every service record must declare. The remaining service-record
# keys are optional, so they are validated one at a time by the `field_*`
# helpers: a schema field cannot express an absent key.
type ServiceIdentity = {name: Str}

# An explicit `log` section must name its mode; its size and keep keys are
# optional.
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

# Result of reaping one inittab child: the updated runtime table plus the
# lifecycle event the death triggers ("poweroff" or "").
type DeadMark = {runtime: List[RuntimeEntry], event: Str}

# Accumulator for the depth-first start-order walk: names already planned and
# the start order built so far.
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

# Result of spawning a service instance: the saved status plus the readiness
# notification fd (>0 only for a `readiness: "notify"` service spawned under the
# scanner; -1 otherwise).
type SpawnResult = {status: SavedStatus, notify_fd: Int}

# A supervised unit: a service plus the runtime state the scanner needs to keep
# it at its desired state. `state` is the internal lifecycle (pending -> starting
# -> running -> dead -> running, or -> stopped); `next_ms`/`current_delay`/
# `started_at` drive non-blocking restart backoff (a future-dated `next_ms` gate
# replaces the blocking sleep the single-service supervisor used to do).
# `notify_fd` holds the readiness pipe while a unit is `starting`. See
# docs/SUPERVISION.md.
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
  xinit [INITTAB]
  xinit boot [TARGET]
  xinit scan [SERVICE|TARGET]
  xinit <start|up|stop|down|restart|reload|status|logs|supervise> SERVICE
  xinit <list|graph> [SERVICE|TARGET]
  xinit check [SERVICE|PATH]
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
    for line in path_value.read_text()?.lines() {
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

# The shared (re)spawn timing gate: a tracked process is due when it holds no
# live pid and its backoff/respawn deadline has elapsed. Both the inittab respawn
# engine and the service scanner gate on this; each then layers its own policy on
# top (inittab: per-action launch limits; scanner: desired state + restart mode).
pure spawn_due(pid: Int, now: Int, next_ms: Int) -> Bool {
  pid <= 0 and now >= next_ms
}

proc spawn_entries(
  entries: List[InittabEntry],
  runtime: List[RuntimeEntry],
  launch_limit: Int,
  delay_ms: Int,
) -> Result[List[RuntimeEntry]] {
  var out = runtime
  let now = time.now()

  for entry in entries {
    if entry_spawns(entry) {
      let current = runtime_get(out, entry.key)

      let launch_allowed = if entry.action == "respawn" {
        launch_limit == 0 or current.launches < launch_limit
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
            next_ms: now + delay_ms,
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
  let action_log = env_value("XSH_INIT_TEST_ACTION_LOG", "")

  if action_log != "" {
    fp"{action_log}".write(f"""{kind}
""")

    return
  }

  if env_enabled("XSH_INIT_FINAL_CLEANUP") or env_value("XSH_INIT_FINAL_CLEANUP", "") == "" {
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

proc run_pid1(inittab: Path) {
  let allow = env_enabled("XINIT_TEST_ALLOW_NON_PID1") or env_enabled("XSH_INIT_TEST_ALLOW_NON_PID1")
  unix.pid1_setup(["HUP", "TERM", "USR1", "USR2", "INT"], subreaper: true, allow_non_pid1: allow)
  let entries = parse_inittab(inittab)?
  let launch_limit = env_int("XSH_INIT_TEST_MAX_RESPAWNS", 0)?
  let delay_ms = env_int("XSH_INIT_TEST_RESPAWN_DELAY_MS", 1000)?
  let exit_when_idle = env_enabled("XSH_INIT_TEST_EXIT_WHEN_IDLE")
  let fast = env_enabled("XSH_INIT_FAST_SHUTDOWN")
  var runtime: List[RuntimeEntry] = []
  var event = ""
  run_phase(entries, "sysinit")
  run_phase(entries, "wait")
  runtime = spawn_entries(entries, runtime, launch_limit, delay_ms)?

  return when should_exit_idle(entries, runtime, exit_when_idle, launch_limit)

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
      runtime = spawn_entries(entries, runtime, launch_limit, delay_ms)?

      return when should_exit_idle(entries, runtime, exit_when_idle, launch_limit)
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

# Error context for a service-record key that failed validation. The service
# file path and key name let an operator find the bad declaration.
pure field_context(source: Path, field: Str) -> Str {
  f"{source}: field `{field}`"
}

# Optional service-record keys. An absent key yields the fallback; a present
# key must hold the declared type (a present null is a type error, not absence).
proc field_str(raw: Record, field: Str, fallback: Str, source: Path) -> Result[Str] {
  return fallback when field not in raw

  raw.get(field)?.require(Str).context("xinit-service", field_context(source, field))?
}

proc field_int(raw: Record, field: Str, fallback: Int, source: Path) -> Result[Int] {
  return fallback when field not in raw

  raw.get(field)?.require(Int).context("xinit-service", field_context(source, field))?
}

proc field_str_list(raw: Record, field: Str, source: Path) -> Result[List[Str]] {
  return [] when field not in raw

  raw.get(field)?.require(List[Str]).context("xinit-service", field_context(source, field))?
}

# A nested optional section (`restart`, `dependencies`, ...); absent reads as an
# empty record so every key inside it takes its default.
proc field_record(raw: Record, field: Str, source: Path) -> Result[Record] {
  if field not in raw {
    let empty: Record = {}
    return empty
  }

  raw.get(field)?.require(Record).context("xinit-service", field_context(source, field))?
}

proc service_from_record(path_value: Path, raw: Record) [process, error] -> Result[Service] {
  let identity = raw.require(ServiceIdentity).context("xinit-service", field_context(path_value, "name"))?
  let kind = field_str(raw, "kind", "longrun", path_value)?

  let command = if "command" in raw {
    raw.get("command")?.require(Command).context("xinit-service", field_context(path_value, "command"))?
  } else {
    process.command_argv("/bin/true", ["true"])
  }

  let restart = field_record(raw, "restart", path_value)?
  let restart_mode = field_str(restart, "mode", if kind == "longrun" { "on_failure" } else { "never" }, path_value)?
  let delay_ms = field_int(restart, "delay_ms", 1000, path_value)?
  let max_delay_ms = field_int(restart, "max_delay_ms", 30000, path_value)?
  let stable_after_ms = field_int(restart, "stable_after_ms", 10000, path_value)?
  let logging = field_str(raw, "logging", "", path_value)?
  let log = field_record(raw, "log", path_value)?
  var log_mode = "append"

  # Built-in append logs are bounded by default: rotate `current` once it reaches
  # `max_size` bytes, keeping `keep` rotated files. `max_size: 0` disables
  # rotation (unbounded, the old behavior).
  var log_max_size = 1048576
  var log_keep = 3

  if "logging" in raw {
    log_mode = logging
  } else if "log" in raw {
    log_mode = log.require(LogPolicy).context("xinit-service", field_context(path_value, "log.mode"))?.mode

    log_max_size = field_int(log, "max_size", log_max_size, path_value)?
    log_keep = field_int(log, "keep", log_keep, path_value)?
  }

  if log_mode == "off" {
    log_mode = "none"
  }

  let targets = field_str_list(raw, "targets", path_value)?
  let deps = field_record(raw, "dependencies", path_value)?
  let need = field_str_list(deps, "need", path_value)?
  let uses = field_str_list(deps, "uses", path_value)?
  let after = field_str_list(deps, "after", path_value)?
  let before = field_str_list(deps, "before", path_value)?
  let resources = field_record(raw, "resources", path_value)?
  let cpu_max = field_int(resources, "cpu_max", 0, path_value)?
  let ready_timeout_ms = field_int(raw, "ready_timeout_ms", 5000, path_value)?
  let stop_timeout_ms = field_int(raw, "stop_timeout_ms", 200, path_value)?
  let readiness = field_str(raw, "readiness", "auto", path_value)?

  {
    name: identity.name,
    path: path_value,
    kind,
    command,
    restart_mode,
    targets,
    need,
    uses,
    after,
    before,
    delay_ms,
    max_delay_ms,
    stable_after_ms,
    stop_timeout_ms,
    log: log_mode,
    log_max_size,
    log_keep,
    cpu_max,
    ready_timeout_ms,
    readiness,
  }
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

proc check_service_graph(services: List[Service]) [error] {
  let names = service_names(services)
  let facilities = builtin_facilities()

  for service in services {
    for dep in dependency_edges(service).extend(service.before) {
      if dep not in names and dep not in facilities {
        return Err(XinitError.Failed(kind: "xinit-deps", message: f"{service.name}: unknown dependency '{dep}'"))
      }
    }
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

# Names that must start for `name` to be considered up: the root plus its
# transitive `need` closure. `uses` deps are deliberately excluded — they are
# optional, so their start failure is tolerated (see start_service).
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

# Liveness probe via signal 0. An Ok result means the pid exists and we may
# signal it, i.e. it is plausibly still our running service. Any error means it
# is gone (ESRCH) or no longer ours (EPERM, e.g. the pid was recycled into
# another user's process); in both cases the saved state is stale, so we treat
# it as not alive. xinit runs as root over its own children, so EPERM does not
# arise for legitimately-owned services in practice.
proc pid_alive(pid: Int) -> Bool {
  guard pid > 0 else {
    return false
  }

  match process.kill(pid, "0") {
    Ok(_) => true
    Err(_) => false
  }
}

# The kernel start time (epoch ms) of a live pid, or 0 if it is not found.
proc pid_start_time(pid: Int) -> Result[Int] {
  guard pid > 0 else {
    return 0
  }

  for entry in process.list()? {
    return entry.start_time_ms when entry.pid == pid
  }

  0
}

# Whether a tracked pid is still our service instance: alive (signal 0) and, when
# a baseline start time was recorded, with a matching kernel start time. The
# start-time check closes the window the bare liveness probe leaves open when a
# dead service's pid is recycled into an unrelated process. A baseline of 0
# (e.g. scanner-managed units, which clear the pid on child exit) skips it.
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

  # Trust the kernel, not the pidfile. A saved "running" state whose tracked pid
  # is no longer alive is stale (the process crashed without cleanup, or the pid
  # was recycled), so reconcile it to "dead" rather than report a phantom or let
  # `stop` signal an unrelated process. Skipped under XSH_UNIX_DRY_RUN, where
  # pids are mocked and `process.kill` would probe the real kernel. A tracked
  # pid of 0 (completed oneshot/scripted service) is left untouched.
  if status.state == "running" and status.pid > 0 and ! env_enabled("XSH_UNIX_DRY_RUN") and ! pid_live_and_ours(
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

# Rotate a service's `current` log, keeping `keep` numbered copies
# (current.1 newest). Uses copy-then-truncate so a running child's append fd
# stays valid; a write landing between the copy and the truncate may be lost,
# which is the accepted V1 tradeoff for in-process rotation without log reopen.
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

  let deadline = time.now() + service.ready_timeout_ms

  while time.now() <= deadline {
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

# Reload a running service in place: run its `reload()` hook if it has one,
# otherwise send SIGHUP to its process group (the usual reload convention).
proc reload_unit(service: Service, pid: Int) {
  if run_reload_proc(service) {} else if pid > 0 {
    unix.kill_process_group(pid, "HUP")
  }
}

# Spawn one instance of a service. `notify` is set by the scanner; combined with
# a `readiness: "notify"` service it spawns with a readiness pipe and reports the
# child not-yet-ready (the scanner polls the returned `notify_fd`). Otherwise
# readiness is resolved inline via the `ready()` hook (or spawned == ready), and
# `notify_fd` is -1.
proc spawn_service(service: Service, restarts: Int, notify: Bool) -> Result[SpawnResult] {
  let cgroup_path = if service.cpu_max > 0 and env_enabled("XSH_UNIX_DRY_RUN") and env_value("XSH_CGROUP_ROOT", "") == "" {
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

  # Rotate before opening so a service that has accumulated a large log across
  # restarts starts a fresh `current` rather than appending to an oversized one.
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

  # CLI start is one-shot and unsupervised: no notify pipe (its read end would
  # die with this process), so readiness resolves inline.
  let spawned = spawn_service(service, current.restarts, false)?
  let base = spawned.status

  # Record the child's kernel start time so a later status read can tell our
  # instance from an unrelated process that reuses the pid after ours exits.
  # (The scanner does not need this — it clears the pid on child exit.)
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

# True when a live scanner owns this run directory. Skipped under
# XSH_UNIX_DRY_RUN (pids are mocked there), so test-mode start/stop stay direct.
proc scanner_active() -> Result[Bool] {
  return false when env_enabled("XSH_UNIX_DRY_RUN")

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
  # When a scanner owns the tree it is the source of truth: post a desired-state
  # request rather than spawning a second, unsupervised copy.
  if scanner_active() {
    request_desired(name, "up")
    return
  }

  let required = required_names(name)?
  var last = default_status(name)

  for item in plan_service_start(name)? {
    # `need` deps (and the service itself) are required: a failure aborts.
    # `uses`-only deps are optional: tolerate their start failure.
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
  # Under a scanner, restart is a single inbox action so the scanner does the
  # teardown-and-respawn itself; a direct stop+start here would race it and
  # spawn an unsupervised second copy.
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
  let doubled = used_ms * 2

  return max_delay_ms when max_delay_ms > 0 and doubled > max_delay_ms

  doubled
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

  # Spawned but not yet ready (awaiting its notify byte).
  return "starting" when unit.state == "starting"

  # Running a finish() cleanup hook after the instance exited.
  return "finishing" when unit.state == "finishing"

  # A unit awaiting a backoff respawn is reported as "dead" so callers can tell
  # it apart from a clean stop; pending and stopped both read as "down".
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

# Advance a `starting` unit toward `running`: ready once its notify byte arrives,
# or — if the ready timeout elapses — promoted to running but not ready, so a
# silent service does not wedge the scanner. The readiness fd is released either
# way.
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

# Reconcile a unit toward its desired state. A `starting` unit advances toward
# ready; a wanted-up unit that is pending or dead and past its backoff gate is
# (re)spawned. Running units (and completed oneshots, pid 0 in state "running")
# return unchanged, so this is cheap to call on every poll.
pure unit_state_of(units: List[ServiceUnit], name: Str) -> Str {
  for unit in units {
    return unit.state when unit.service.name == name
  }

  ""
}

# Whether a unit's ordering dependencies are satisfied enough for its first
# start. A `need` dep must be `running` (its startup, including readiness, has
# completed); `uses`/`after` deps may also be `stopped` (settled — optional or
# ordering-only, so a failed one does not block forever). Deps that are not
# scanned units (facilities, or absent) impose no gate. Respawns are not gated;
# only the initial pending -> running transition waits.
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

# True for a pending unit that cannot start yet because a dependency is still
# coming up. Used to gate the initial start and to avoid spinning the scanner
# while it waits (the dependency's own transitions drive the wakeups).
pure unit_blocked(units: List[ServiceUnit], unit: ServiceUnit) -> Bool {
  unit.desired == "up" and unit.state == "pending" and ! gate_satisfied(units, unit.service)
}

proc reconcile_one(unit: ServiceUnit, units: List[ServiceUnit], now: Int) -> Result[ServiceUnit] {
  return advance_readiness(unit, now)? when unit.state == "starting"

  return unit when unit.desired != "up"

  return unit when unit.state != "pending" and unit.state != "dead"

  # Dependency-ordered readiness gating: an initial start waits until its
  # ordering deps are up. Respawns (state "dead") are not gated.
  return unit when unit.state == "pending" and ! gate_satisfied(units, unit.service)

  # Pending/dead units hold pid 0, so this is the shared backoff gate.
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

# Reconcile every unit against a single start-of-pass snapshot, so gating reads
# consistent dependency states regardless of iteration order.
proc reconcile_all(units: List[ServiceUnit], now: Int) -> Result[List[ServiceUnit]] {
  [reconcile_one(unit, units, now)? for unit in units]
}

# Apply the death of a unit's child: either schedule a backoff respawn (the
# `next_ms` gate, so reconcile relaunches on a later pass without blocking the
# scanner) or, when the restart policy declines, mark the unit stopped. Backoff
# resets to the base delay after an instance stayed up at least stable_after_ms.
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

# Run a service's finish() cleanup hook after its instance has exited (on stop
# or crash). While the hook runs the unit is reported as "finishing". A service
# with no finish() hook is left untouched.
proc run_finish(unit: ServiceUnit) {
  require_service_file(unit.service.path)
  let loaded = module.load(unit.service.path)?.require(ServiceFile)?

  if "finish" in loaded.keys() {
    write_status(unit_saved_status(finishing_unit(unit)))
    loaded.finish()
  }
}

proc mark_unit_dead(unit: ServiceUnit, child_status: Status, now: Int) -> Result[ServiceUnit] {
  # The child is already gone; release any readiness fd it held, then run the
  # finish() cleanup hook before deciding the unit's next state.
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

  let reset = now - unit.started_at >= unit.service.stable_after_ms
  let delay = if reset { unit.service.delay_ms } else { unit.current_delay }

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

# Tear down a unit's running instance: run its `stop()` hook if it has one,
# otherwise TERM then KILL the process group. No status write; callers decide
# the resulting unit state.
proc kill_unit(unit: ServiceUnit) {
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

  # Cleanup hook after the instance is down.
  run_finish(unit)
}

# Stop a unit directly, with no dependency-refusal check (that belongs to the
# operator-facing `stop` command, not to scanner-driven shutdown).
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

# Apply one desired-state request to a single unit. "down" stops a running unit
# and parks it; "up" makes it schedulable again (reconcile spawns it on the next
# pass). A request for a different unit name is a no-op.
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

  # "reload" refreshes a running unit in place (reload() hook or SIGHUP) without
  # changing its state.
  if desired == "reload" {
    if unit.state == "running" or unit.state == "starting" {
      reload_unit(unit.service, unit.pid)
    }

    return unit
  }

  # "restart" tears down the current instance and re-arms the unit for an
  # immediate respawn on the next reconcile pass. A desired-state slot cannot
  # hold a transient, so restart is expressed as its own inbox action.
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

  # "up": an already-active unit (running or starting) is left as-is; an
  # idle/stopped one is re-armed so reconcile spawns it on the next pass.
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

# Drain the control inbox: each request file is named for a service and holds
# "up" or "down". This is the supervisor side of the control plane — operators
# (and `start`/`stop` when a scanner owns the tree) post desired-state requests
# rather than signalling a pid, so the scanner stays the source of truth.
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

# The unified scanner: hold a set of units and reconcile them toward their
# desired state on every wakeup. `wait_pid1_event` returns a `poll` event within
# ~100ms even when idle, so the loop re-checks backoff gates without a dedicated
# timer. This is the single supervision mechanism behind both `supervise` (one
# unit) and `scan` (a whole dependency tree).
# A `starting` unit has no notify_fd event to wait on, so the scanner polls its
# readiness on this cadence rather than spinning (a zero wait would busy-loop a
# notify service's whole startup at 100% CPU).
pure readiness_poll_ms() -> Int {
  100
}

pure due_ms(unit: ServiceUnit, now: Int) -> Int {
  let due = unit.next_ms - now

  return 0 when due < 0

  due
}

# How long the scanner may block before it must reconcile again: the soonest
# pending/dead unit's backoff gate, the readiness poll cadence for starting
# units, else an hour. wait_pid1_event still wakes within ~100ms for signals and
# children, so the long ceiling only bounds idle sleeps.
pure next_wait_ms(units: List[ServiceUnit], now: Int) -> Int {
  var soonest = -1

  for unit in units {
    # A pending unit blocked on a dependency is not "due" — its wakeup comes from
    # the dependency's own transition (a starting poll, a respawn deadline, or a
    # child exit), so skipping it here keeps the scanner from spinning.
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

# Bound the logs of running services: a long-lived instance that never restarts
# would otherwise grow `current` without limit. Copy-truncates over the cap each
# pass; the rotate-on-spawn path covers services that crash and restart.
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
  var remaining = env_int("XINIT_TEST_MAX_EVENTS", -1)?
  var shutting_down = false
  write_scanner_marker()

  while true {
    if ! shutting_down {
      units = drain_inbox(units)?
    }

    units = reconcile_all(units, time.now())?
    enforce_log_caps(units)

    return when shutting_down and all_units_stopped(units)

    return when remaining == 0

    let event = unix.wait_pid1_event(timeout: time.millis(next_wait_ms(units, time.now())))?

    if remaining > 0 {
      remaining -= 1
    }

    if event.kind == "signal" and (event.signal == "TERM" or event.signal == "INT") {
      units = shutdown_all(units)?
      shutting_down = true
    } else if event.kind == "children" {
      let now = time.now()

      for child in event.children {
        units = mark_children_dead(units, child.pid, child.status, now)?
      }
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
  let parsed = cli.commands(
    argv,
    rootless_default: "pid1",
    commands: {
      pid1: {
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
    fallback_command: {positionals: ["inittab"], types: {inittab: "Path"}, rest: "args"},
  )?

  if parsed.command == "pid1" {
    guard parsed.args.is_empty() else {
      return Err(XinitError.Failed(kind: "xinit-control", message: "usage: xinit"))
    }

    run_pid1(fp"{env_value("XSH_INIT_INITTAB", "/etc/inittab")}")
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

    control(parsed.action, parsed.get("service")?.require()?)
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

    run_pid1(parsed.get("inittab")?.require()?)
  }
}
