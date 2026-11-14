##! Stop the configured xinit services for a backup window and restore only the stops this attempt owns.

## Default service transition timeout in milliseconds.
export const QUIESCE_DEFAULT_TIMEOUT_MS = 30000
## Maximum service transition timeout in milliseconds.
export const QUIESCE_MAX_TIMEOUT_MS = 3600000
## Default bound of one release attempt in milliseconds.
export const QUIESCE_DEFAULT_RELEASE_TIMEOUT_MS = 60000
## Default wait between the supervisor's release attempts in milliseconds.
export const QUIESCE_DEFAULT_RETRY_DELAY_MS = 30000
## Default number of supervisor release attempts before the record is left for an operator.
export const QUIESCE_DEFAULT_MAX_ATTEMPTS = 5
## Largest accepted retry count.
export const QUIESCE_MAX_ATTEMPTS = 20
## Version of one quiescence record.
export const QUIESCE_RECORD_FORMAT = "laputa-quiesce-1"
## The xinit per-service state directory.
export const QUIESCE_STATE_DIR = p"/run/xinit"
## Where the timer supervisor keeps one quiescence record per job.
export const QUIESCE_RECORD_DIR = p"/var/lib/laputa-timers/quiesce"
## Where the timer supervisor keeps the identity of each running attempt.
export const QUIESCE_WRITER_DIR = p"/var/lib/laputa-timers/runs"

const QUIESCE_USAGE = """usage: backup-quiesce <stop|start> SERVICE... [--timeout-ms N] [--recover-timeout-ms N] [--recover-retry-ms N] [--recover-attempts N]
       backup-quiesce reconcile JOB

stop       record the services that are up, then stop each with an ownership token
start      restore the stops this attempt still owns and retire its record
reconcile  the same restore for one job's record, run by the timer supervisor

Quiescence runs under the timer supervisor only; start a backup job with
`timers.xsh run-now JOB`.
"""
const QUIESCE_TOKEN_RE = rx"^[A-Za-z0-9_.-]{1,32}$"
const QUIESCE_JOB_RE = rx"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"

## The parsed command line.
export type QuiesceOptions = {
  action: Str,
  services: List[Str],
  timeout_ms: Int,
  release_timeout_ms: Int,
  retry_delay_ms: Int,
  max_attempts: Int,
  help: Bool,
}

## One service of an attempt. `acquired` services were up and are the attempt's to restore.
export type QuiesceService = {name: Str, prior_desired: Str, acquired: Bool}

## The durable account of one quiescing attempt, outside the backup process.
export type QuiesceRecord = {
  job: Str,
  attempt: Int,
  token: Str,
  boot_id: Str,
  created_wall_ms: Int,
  timeout_ms: Int,
  release_timeout_ms: Int,
  retry_delay_ms: Int,
  max_attempts: Int,
  services: List[QuiesceService],
}

## Where the hook finds xinit and its state, and where the records live.
export type QuiesceEnv = {xinit: List[Str], state_dir: Path, records: Path, writers: Path, scratch: Path}

## The production locations.
export pure quiesce_env_default() -> QuiesceEnv {
  {
    xinit: ["/usr/bin/xinit"],
    state_dir: QUIESCE_STATE_DIR,
    records: QUIESCE_RECORD_DIR,
    writers: QUIESCE_WRITER_DIR,
    scratch: p"/run/laputa-backup",
  }
}

pure quiesce_int_option(argv: List[Str], index: Int, flag: Str, low: Int, high: Int) -> Result[Int, Str] {
  guard index < argv.len() else {
    return Err(f"{flag} requires a value")
  }
  let value = match argv[index].parse_int() {
    Ok(parsed) => parsed,
    Err(_) => { return Err(f"{flag} requires an integer") },
  }
  guard value >= low and value <= high else {
    return Err(f"{flag} must be {low}..{high}")
  }
  Ok(value)
}

## Decode the command line.
export pure quiesce_options(argv: List[Str]) -> Result[QuiesceOptions, Str] {
  var options = QuiesceOptions(
    action: "",
    services: [],
    timeout_ms: QUIESCE_DEFAULT_TIMEOUT_MS,
    release_timeout_ms: QUIESCE_DEFAULT_RELEASE_TIMEOUT_MS,
    retry_delay_ms: QUIESCE_DEFAULT_RETRY_DELAY_MS,
    max_attempts: QUIESCE_DEFAULT_MAX_ATTEMPTS,
    help: false,
  )
  var index = 0
  while index < argv.len() {
    let word = argv[index]
    index += 1
    if word == "--help" or word == "-h" or word == "help" {
      options.help = true
      continue
    }
    if word == "--timeout-ms" {
      options.timeout_ms = quiesce_int_option(argv, index, word, 1, QUIESCE_MAX_TIMEOUT_MS)?
      index += 1
      continue
    }
    if word == "--recover-timeout-ms" {
      options.release_timeout_ms = quiesce_int_option(argv, index, word, 1, QUIESCE_MAX_TIMEOUT_MS)?
      index += 1
      continue
    }
    if word == "--recover-retry-ms" {
      options.retry_delay_ms = quiesce_int_option(argv, index, word, 1, QUIESCE_MAX_TIMEOUT_MS)?
      index += 1
      continue
    }
    if word == "--recover-attempts" {
      options.max_attempts = quiesce_int_option(argv, index, word, 1, QUIESCE_MAX_ATTEMPTS)?
      index += 1
      continue
    }
    if word.starts_with("-") {
      return Err(f"unknown option {word}")
    }
    if options.action == "" {
      guard word == "stop" or word == "start" or word == "reconcile" else {
        return Err("action must be stop, start, or reconcile")
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
    return Err(if options.action == "reconcile" { "a job name is required" } else { "at least one service is required" })
  }
  guard options.action != "reconcile" or options.services.len() == 1 else {
    return Err("reconcile takes exactly one job name")
  }
  Ok(options)
}

## The ownership token of one attempt; unique per job, wall time and attempt.
export pure quiesce_token(wall_ms: Int, attempt: Int) -> Str {
  f"q{wall_ms}a{attempt}"
}

## What one release pass does for a service the attempt may own: `done` when the stop is not
## (or no longer) this attempt's and nothing is queued, `wait` while a request is queued, and
## `request` to hand the stop back with a conditional start.
export pure quiesce_release_step(token: Str, owner: Str, queued: Bool) -> Str {
  if queued {
    return "wait"
  }
  if owner == token {
    return "request"
  }
  "done"
}

## Decode one record, refusing anything this hook did not write.
export pure quiesce_record_from_json(value: Any) -> Result[QuiesceRecord, Error] {
  let format = json.get(value, ["format"], "").require(Str)?
  guard format == QUIESCE_RECORD_FORMAT else {
    return Err(error.failure(f"unsupported quiescence record format {format}"))
  }
  let job = json.get(value, ["job"], "").require(Str)?
  guard QUIESCE_JOB_RE.matches(job) else {
    return Err(error.failure("quiescence record has an invalid job name"))
  }
  let token = json.get(value, ["token"], "").require(Str)?
  guard QUIESCE_TOKEN_RE.matches(token) else {
    return Err(error.failure(f"quiescence record of {job} has an invalid token"))
  }
  var services: List[QuiesceService] = []
  for item in json.get(value, ["services"], []).require(List[Any])? {
    let name = json.get(item, ["name"], "").require(Str)?
    guard QUIESCE_JOB_RE.matches(name) else {
      return Err(error.failure(f"quiescence record of {job} names an invalid service"))
    }
    services += [QuiesceService(
      name: name,
      prior_desired: json.get(item, ["prior_desired"], "down").require(Str)?,
      acquired: json.get(item, ["acquired"], false).require(Bool)?,
    )]
  }
  Ok({
    job: job,
    attempt: json.get(value, ["attempt"], 0).require(Int)?,
    token: token,
    boot_id: json.get(value, ["boot_id"], "").require(Str)?,
    created_wall_ms: json.get(value, ["created_wall_ms"], 0).require(Int)?,
    timeout_ms: json.get(value, ["timeout_ms"], QUIESCE_DEFAULT_TIMEOUT_MS).require(Int)?,
    release_timeout_ms: json.get(value, ["release_timeout_ms"], QUIESCE_DEFAULT_RELEASE_TIMEOUT_MS).require(Int)?,
    retry_delay_ms: json.get(value, ["retry_delay_ms"], QUIESCE_DEFAULT_RETRY_DELAY_MS).require(Int)?,
    max_attempts: json.get(value, ["max_attempts"], QUIESCE_DEFAULT_MAX_ATTEMPTS).require(Int)?,
    services: services,
  })
}

proc quiesce_status(qe: QuiesceEnv, service: Str) [fs, error] -> Result[Record?, Error] {
  let target = fp"{qe.state_dir}/{service}.json"
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

proc quiesce_owner(qe: QuiesceEnv, service: Str) [fs, error] -> Result[Str, Error] {
  let file = fp"{qe.state_dir}/{service}.control"
  if ! file.exists() {
    return Ok("")
  }
  Ok(file.read_text()?.trim())
}

proc quiesce_xinit(qe: QuiesceEnv, args: List[Str]) [fs, process, error] -> Result[Str, Error] {
  qe.scratch.mkdir(parents: true)?
  let errors = fp"{qe.scratch}/quiesce-xinit.err"
  errors.remove(missing_ok: true)?
  let status = process.run(process.command_argv(
    qe.xinit[0],
    qe.xinit + args,
    cwd: p"/",
    stdin: p"/dev/null",
    stdout: p"/dev/null",
    stderr: errors,
  ))?
  let text = if errors.exists() { errors.read_text()?.trim() } else { "" }
  errors.remove(missing_ok: true)?
  guard status.ok else {
    return Err(error.failure(f"xinit {args.join(" ")} failed: {text}"))
  }
  Ok(text)
}

proc quiesce_wait(qe: QuiesceEnv, service: Str, up: Bool, timeout_ms: Int) [fs, time, io, error] -> Result[Unit, Error] {
  var waited = 0
  while true {
    let value = quiesce_status(qe, service)?
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

proc quiesce_record_file(qe: QuiesceEnv, job: Str) -> Path {
  fp"{qe.records}/{job}.json"
}

## Durably write the record. It must exist before the first service is stopped.
export proc quiesce_write_record(qe: QuiesceEnv, record: QuiesceRecord) [fs, error] -> Result[Unit, Error] {
  qe.records.mkdir(parents: true)?
  let file = quiesce_record_file(qe, record.job)
  let body = json.encode({
    format: QUIESCE_RECORD_FORMAT,
    job: record.job,
    attempt: record.attempt,
    token: record.token,
    boot_id: record.boot_id,
    created_wall_ms: record.created_wall_ms,
    timeout_ms: record.timeout_ms,
    release_timeout_ms: record.release_timeout_ms,
    retry_delay_ms: record.retry_delay_ms,
    max_attempts: record.max_attempts,
    services: record.services,
  })? + "\n"
  atomically replace file as next {
    next.write(body, mode: 0o600)
    fs.fsync(next)
  }
  fs.fsync(qe.records)
}

## Read one job's record, or null when none is outstanding.
export proc quiesce_read_record(qe: QuiesceEnv, job: Str) [fs, error] -> Result[QuiesceRecord?, Error] {
  let file = quiesce_record_file(qe, job)
  if ! file.exists() {
    return Ok(null)
  }
  Ok(quiesce_record_from_json(json.read(file)?)?)
}

## Build the record of an attempt from the services' current desired states.
export proc quiesce_plan(
  qe: QuiesceEnv,
  job: Str,
  attempt: Int,
  services: List[Str],
  boot_id: Str,
  wall_ms: Int,
  options: QuiesceOptions,
) [fs, error] -> Result[QuiesceRecord, Error] {
  var planned: List[QuiesceService] = []
  for name in services {
    let status = quiesce_status(qe, name)?
    let desired = if status == null { "down" } else { json.get(status, ["desired"], "down").require(Str) ?? "down" }
    planned += [QuiesceService(name: name, prior_desired: desired, acquired: desired == "up")]
  }
  Ok({
    job: job,
    attempt: attempt,
    token: quiesce_token(wall_ms, attempt),
    boot_id: boot_id,
    created_wall_ms: wall_ms,
    timeout_ms: options.timeout_ms,
    release_timeout_ms: options.release_timeout_ms,
    retry_delay_ms: options.retry_delay_ms,
    max_attempts: options.max_attempts,
    services: planned,
  })
}

## Stop one acquired service under the attempt's token and wait until it is down.
export proc quiesce_stop_service(qe: QuiesceEnv, record: QuiesceRecord, service: Str) [fs, process, time, io, error] -> Result[Unit, Error] {
  let _ = quiesce_xinit(qe, ["stop", "--owner", record.token, service])?
  quiesce_wait(qe, service, false, record.timeout_ms)
}

## Hand one service back if this attempt still owns its stop. A later operator command, or a
## service the attempt never stopped, is left exactly as it is.
export proc quiesce_release_service(qe: QuiesceEnv, record: QuiesceRecord, service: Str, timeout_ms: Int) [fs, process, time, io, error] -> Result[Unit, Error] {
  var waited = 0
  var last = ""
  while true {
    let owner = quiesce_owner(qe, service)?
    let queued = fp"{qe.state_dir}/inbox/{service}".exists()?
    let step = quiesce_release_step(record.token, owner, queued)
    if step == "done" {
      return Ok()
    }
    if step == "request" {
      match quiesce_xinit(qe, ["start", "--if-owner", record.token, service]) {
        Ok(_) => {}
        Err(problem) => { last = problem.message }
      }
    }
    guard waited < timeout_ms else {
      return Err(error.failure(f"service {service} is still stopped by {record.token} after {timeout_ms}ms {last}"))
    }
    time.sleep(100ms)?
    waited += 100
  }
  Ok()
}

## Restore every stop the record owns, then retire it. A `timeout_ms` of 0 uses the record's own bound. Safe to repeat: a service already handed
## back, superseded by an operator, or never stopped costs no transition. The record stays when
## any service could not be released.
export proc quiesce_release_record(qe: QuiesceEnv, job: Str, timeout_ms: Int) [fs, process, time, io, error] -> Result[Bool, Error] {
  let found = quiesce_read_record(qe, job)?
  guard let record = found else {
    return Ok(false)
  }
  let bound = if timeout_ms > 0 { timeout_ms } else { record.release_timeout_ms }
  var failures: List[Str] = []
  var restored: List[Str] = []
  for service in record.services {
    if ! service.acquired {
      continue
    }
    match quiesce_release_service(qe, record, service.name, bound) {
      Ok(_) => { restored += [service.name] }
      Err(problem) => { failures += [problem.message] }
    }
  }
  guard failures.is_empty() else {
    return Err(error.failure(failures.join("; ")))
  }
  quiesce_record_file(qe, job).remove(missing_ok: true)?
  fs.fsync(qe.records)
  for name in restored {
    match quiesce_wait(qe, name, true, record.timeout_ms) {
      Ok(_) => {}
      Err(problem) => { print f"quiesce service={name} released note={problem.message}" }
    }
  }
  Ok(true)
}

proc quiesce_supervised(qe: QuiesceEnv, job: Str, attempt: Int) [fs, process, error] -> Result[Unit, Error] {
  let file = fp"{qe.writers}/{job}.json"
  guard file.exists()? else {
    return Err(error.failure(f"{job} has no supervised attempt: quiescence runs under the timer supervisor"))
  }
  let writer = json.read(file)?
  let pid = json.get(writer, ["pid"], 0).require(Int)?
  guard pid > 1 and pid == process.session_id()? and json.get(writer, ["attempt"], 0).require(Int)? == attempt else {
    return Err(error.failure(f"this process is not the supervised attempt of {job}"))
  }
}

proc quiesce_boot_id() [fs] -> Str {
  match p"/proc/sys/kernel/random/boot_id".read_text() {
    Ok(text) => text.trim()
    Err(_) => ""
  }
}

## Quiesce the services of one supervised attempt: record first, then stop what was up.
export proc quiesce_acquire(qe: QuiesceEnv, job: Str, attempt: Int, options: QuiesceOptions) [fs, process, time, io, error] -> Result[Unit, Error] {
  guard job != "" else {
    return Err(error.failure("quiescence runs under the timer supervisor: run the job with `timers.xsh run-now JOB`"))
  }
  quiesce_supervised(qe, job, attempt)?
  guard quiesce_read_record(qe, job)? == null else {
    return Err(error.failure(f"a previous quiescence of {job} is not released"))
  }
  let record = quiesce_plan(qe, job, attempt, options.services, quiesce_boot_id(), time.now(), options)?
  quiesce_write_record(qe, record)?
  for service in record.services {
    if service.acquired {
      quiesce_stop_service(qe, record, service.name)?
    } else {
      print f"quiesce service={service.name} desired=down state=down note=already-stopped"
    }
  }
  Ok()
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
  let qe = quiesce_env_default()
  if parsed.action == "stop" {
    return quiesce_acquire(qe, e"LAPUTA_TIMER_NAME" ?? "", (e"LAPUTA_TIMER_ATTEMPT" ?? "0").parse_int()?, parsed)
  }
  let job = if parsed.action == "reconcile" { parsed.services[0] } else { e"LAPUTA_TIMER_NAME" ?? "" }
  guard QUIESCE_JOB_RE.matches(job) else {
    return Err(error.failure("quiescence runs under the timer supervisor: no job name"))
  }
  let released = quiesce_release_record(qe, job, 0)?
  print f"quiesce job={job} released={released}"
  Ok()
}

## Entry point when this module runs as a script.
export proc main(...argv: List[Str]) [fs, process, time, io, error] -> Result[Unit, Error] {
  quiesce_main(@argv)
}
