##! A small supervised timer scheduler for xinit.
##!
##! One foreground process owns every job; PID 1 supervises only this process.
##! Job definitions are immutable generation input under /etc. Run state lives
##! on the maintained state disk.
##!
##! Interval schedules are measured on the process monotonic clock. Calendar
##! schedules are UTC wall times. A wall correction never moves an interval
##! deadline; calendar deadlines are re-evaluated from the corrected wall. At
##! most one run represents any number of missed occurrences. No side effect is
##! exactly-once: a run may repeat after a crash or be skipped by policy, so
##! every job must be idempotent or reconcile its own effects.

use lib.monotonic

## Version of one job definition file.
export const TIMER_JOB_FORMAT = "laputa-timer-job-1"
## Version of the durable per-job state file.
export const TIMER_STATE_FORMAT = "laputa-timers-state-1"
## Version of the live inspection snapshot.
export const TIMER_STATUS_FORMAT = "laputa-timers-status-1"

## Version of one durable snapshot-writer record.
export const TIMER_WRITER_FORMAT = "laputa-timer-writer-1"
## The state subdirectory holding one writer record per running attempt.
export const TIMER_WRITER_DIR = "runs"
## The state subdirectory holding one quiescence record per job, written by the job's hook.
export const TIMER_QUIESCE_DIR = "quiesce"
## The state subdirectory of run-now markers; the file name is the job.
export const TIMER_TRIGGER_DIR = "trigger"
## The command that releases one job's quiescence record; the job name is appended.
export const TIMER_RELEASE_COMMAND = ["/usr/bin/xsh", "/usr/lib/laputa/backup-quiesce.xsh", "reconcile"]
## Extra time the supervisor grants a release command beyond its own per-service bounds.
export const TIMER_RELEASE_MARGIN_MS = 10000

## The generation-owned job definition directory.
export const TIMER_JOB_DIR = p"/etc/laputa/timers/jobs.d"
## The state-disk directory that holds run state and cancellation markers.
export const TIMER_STATE_DIR = p"/var/lib/laputa-timers"
## The volatile run directory that holds the live inspection snapshot and the lock.
export const TIMER_RUN_DIR = p"/run/laputa-timers"
## Durable state file name.
export const TIMER_STATE_NAME = "state.json"
## Live inspection snapshot file name.
export const TIMER_STATUS_NAME = "status.json"
## Cancellation marker directory name, beneath the state directory.
export const TIMER_CANCEL_DIR = "cancel"
## Exclusive scheduler lock file name, beneath the run directory.
export const TIMER_LOCK_NAME = "scheduler.lock"

## Maximum definitions read in one generation.
export const TIMER_MAX_JOBS = 64
## Maximum argv length of one job.
export const TIMER_MAX_ARGV = 64
## Shortest interval; with the poll cap an on-time run is never mistaken for a missed one.
export const TIMER_MIN_INTERVAL_MS = 1000
## Longest interval, 365 days.
export const TIMER_MAX_INTERVAL_MS = 31536000000
## Longest per-run timeout; zero disables the timeout.
export const TIMER_MAX_TIMEOUT_MS = 86400000
## Maximum retries after a failed attempt.
export const TIMER_MAX_RETRIES = 10
## Longest retry delay on the monotonic clock.
export const TIMER_MAX_RETRY_DELAY_MS = 3600000
## Wall-versus-monotonic drift that counts as a clock step rather than poll jitter.
export const TIMER_STEP_TOLERANCE_MS = 2000
## Longest sleep between scheduler passes.
export const TIMER_POLL_MAX_MS = 500
## Grace between TERM and KILL when a run times out or is cancelled.
export const TIMER_KILL_GRACE_MS = 2000
## Milliseconds in one UTC day.
export const TIMER_DAY_MS = 86400000

const TIMER_HOUR_MS = 3600000
const TIMER_MINUTE_MS = 60000
const TIMER_NAME_RE = rx"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"
const TIMER_USAGE = """usage: timers [run|status|cancel NAME|resume NAME|run-now NAME] [--jobs DIR] [--state DIR] [--run-dir DIR] [--json]

run     supervise the job definitions until stopped (default)
status  print last and next results per job
cancel  stop starting one job and terminate its running process
resume  clear one job's cancellation
run-now start one job's attempt now, under supervision
"""

## One monotonic and wall reading taken together. `mono_ms` is process-local and never persisted.
export type TimerClock = {mono_ms: Int, wall_ms: Int}

## A validated job. Interval jobs use `every_ms`; calendar jobs use `hour`/`minute` in UTC.
export type TimerJob = {
  name: Str,
  file: Str,
  schedule: Str,
  every_ms: Int,
  hour: Int,
  minute: Int,
  argv: List[Str],
  timeout_ms: Int,
  overlap: Str,
  missed: Str,
  retries: Int,
  retry_delay_ms: Int,
}

## A definition that did not validate, kept for inspection.
export type TimerProblem = {name: Str, file: Str, message: Str}

## Every valid definition and every rejected one.
export type TimerJobs = {jobs: List[TimerJob], problems: List[TimerProblem]}

## One job's durable record. Only wall observations are persisted.
export type TimerState = {
  name: Str,
  last_start_wall_ms: Int?,
  last_finish_wall_ms: Int?,
  last_outcome: Str,
  last_exit_code: Int?,
  runs: Int,
  failures: Int,
  coalesced: Int,
  skipped_missed: Int,
  skipped_overlap: Int,
  queued: Int,
  cancelled: Int,
  calendar_next_wall_ms: Int?,
}

## The due decision for one job at one observation. `missed` counts the scheduled
## occurrences this decision represents without running them.
export type TimerDue = {
  kind: Str,
  missed: Int,
  next_mono_ms: Int,
  next_wall_ms: Int,
  next_in_ms: Int,
}

## A scheduler-observed clock discontinuity.
export type TimerStep = {kind: Str, wall_delta_ms: Int, mono_delta_ms: Int, at_wall_ms: Int}

## The durable last result of one job.
export type TimerLast = {start_wall_ms: Int?, finish_wall_ms: Int?, outcome: Str, exit_code: Int?}

## The next occurrence of one job.
export type TimerNext = {wall_ms: Int?, in_ms: Int, source: Str}

## The bounded counters of one job.
export type TimerCounts = {
  runs: Int,
  failures: Int,
  coalesced: Int,
  skipped_missed: Int,
  skipped_overlap: Int,
  queued: Int,
  cancelled: Int,
}

## The retry position of one job.
export type TimerRetry = {attempt: Int, in_ms: Int}

## One job as the status command reports it.
export type TimerStatusJob = {
  name: Str,
  file: Str,
  schedule: Str,
  every_ms: Int,
  hour: Int,
  minute: Int,
  overlap: Str,
  missed: Str,
  retries: Int,
  state: Str,
  next: TimerNext,
  last: TimerLast,
  retry: TimerRetry,
  counts: TimerCounts,
  cancelled: Bool,
}

## The whole inspection snapshot, written to the run directory and printed by `status`.
export type TimerStatus = {
  format: Str,
  scheduler_pid: Int,
  boot_id: Str,
  armed_wall_ms: Int,
  sampled_wall_ms: Int,
  resume: Str,
  last_step: TimerStep?,
  jobs: List[TimerStatusJob],
  invalid: List[TimerProblem],
}

## The live per-job view used to build the snapshot.
export type TimerView = {
  state: Str,
  next_wall_ms: Int?,
  next_in_ms: Int,
  next_source: Str,
  retry_attempt: Int,
  retry_in_ms: Int,
}

## The scheduler's private position for one job. Monotonic values never leave the process.
export type TimerRuntime = {
  next_mono_ms: Int,
  next_wall_ms: Int,
  running: Bool,
  pending_start: Bool,
  pending_missed: Int,
  queued: Bool,
  queued_wall_ms: Int,
  retry_attempt: Int,
  retry_at_mono_ms: Int,
  retry_missed: Int,
  retry_wall_ms: Int,
}

## One live child. The handle keeps the run observable and terminable.
export type TimerRunning = {
  name: Str,
  handle: ProcessHandle,
  deadline_mono_ms: Int,
  occurrence_wall_ms: Int,
  attempt: Int,
  missed: Int,
}

## One attempted start: the live child, or the failure it recorded.
export type TimerStartOutcome = {started: TimerRunning?, state: TimerState, runtime: TimerRuntime}

## The process identity the supervisor persists for one attempt. `pid` is the session the
## attempt leads, which also contains every tool group the job starts; `start_time_ms` is the leader's kernel start time.
export type TimerWriter = {
  name: Str,
  attempt: Int,
  boot_id: Str,
  pid: Int,
  start_time_ms: Int,
  started_wall_ms: Int,
}

## Where writer records live, and the boot they are judged against.
export type TimerWriterStore = {dir: Path, quiesce_dir: Path, boot_id: Str}

## The supervisor's release bookkeeping for one job. Monotonic values never leave the process.
export type TimerRelease = {due_mono_ms: Int, attempts: Int, reported: Bool}

## The release bounds a job's hook published in its quiescence record.
export type TimerReleasePolicy = {release_timeout_ms: Int, retry_delay_ms: Int, max_attempts: Int, services: Int}

type SchedulerConfig = {job_dir: Path, state_dir: Path, run_dir: Path}

type TimerOptions = {action: Str, name: Str, job_dir: Str, state_dir: Str, run_dir: Str, json: Bool, help: Bool}

## Whether `name` is a job name the scheduler accepts.
export pure timer_name_ok(name: Str) -> Bool {
  TIMER_NAME_RE.matches(name)
}

## The next UTC occurrence of `hour:minute` strictly after `after_wall_ms`.
export pure timer_calendar_next(hour: Int, minute: Int, after_wall_ms: Int) -> Int {
  let day_start = after_wall_ms - after_wall_ms % TIMER_DAY_MS
  let candidate = day_start + hour * TIMER_HOUR_MS + minute * TIMER_MINUTE_MS
  if candidate <= after_wall_ms { candidate + TIMER_DAY_MS } else { candidate }
}

## Scheduled occurrences in `[next_wall_ms, now_wall_ms]`; zero before the anchor.
export pure timer_calendar_occurrences(next_wall_ms: Int, now_wall_ms: Int) -> Int {
  if now_wall_ms < next_wall_ms {
    0
  } else {
    1 + (now_wall_ms - next_wall_ms) / TIMER_DAY_MS
  }
}

## The interval decision at one monotonic reading.
export pure timer_interval_due(interval_ms: Int, next_mono_ms: Int, now_mono_ms: Int, missed: Str) -> TimerDue {
  if now_mono_ms < next_mono_ms {
    return {
      kind: "wait",
      missed: 0,
      next_mono_ms: next_mono_ms,
      next_wall_ms: 0,
      next_in_ms: next_mono_ms - now_mono_ms,
    }
  }
  let occurrences = 1 + (now_mono_ms - next_mono_ms) / interval_ms
  let collapsed = occurrences - 1
  let following = now_mono_ms + interval_ms
  if missed == "skip" and collapsed > 0 {
    return {kind: "skipped-missed", missed: occurrences, next_mono_ms: following, next_wall_ms: 0, next_in_ms: interval_ms}
  }
  {
    kind: if collapsed > 0 { "coalesced-start" } else { "start" },
    missed: collapsed,
    next_mono_ms: following,
    next_wall_ms: 0,
    next_in_ms: interval_ms,
  }
}

## The calendar decision at one wall reading. An anchor more than a day ahead can
## only follow a backward wall step, so it is re-anchored to the corrected wall.
export pure timer_calendar_due(hour: Int, minute: Int, next_wall_ms: Int, now_wall_ms: Int, missed: Str) -> TimerDue {
  let occurrences = timer_calendar_occurrences(next_wall_ms, now_wall_ms)
  if occurrences == 0 {
    if next_wall_ms - now_wall_ms > TIMER_DAY_MS {
      let anchored = timer_calendar_next(hour, minute, now_wall_ms)
      return {kind: "wait", missed: 0, next_mono_ms: 0, next_wall_ms: anchored, next_in_ms: anchored - now_wall_ms}
    }
    return {
      kind: "wait",
      missed: 0,
      next_mono_ms: 0,
      next_wall_ms: next_wall_ms,
      next_in_ms: next_wall_ms - now_wall_ms,
    }
  }
  let collapsed = occurrences - 1
  let following = timer_calendar_next(hour, minute, now_wall_ms)
  if missed == "skip" and collapsed > 0 {
    return {
      kind: "skipped-missed",
      missed: occurrences,
      next_mono_ms: 0,
      next_wall_ms: following,
      next_in_ms: following - now_wall_ms,
    }
  }
  {
    kind: if collapsed > 0 { "coalesced-start" } else { "start" },
    missed: collapsed,
    next_mono_ms: 0,
    next_wall_ms: following,
    next_in_ms: following - now_wall_ms,
  }
}

## The interval decision when the scheduler arms. The wall clock estimates the
## downtime that monotonic time cannot cover across a reboot.
export pure timer_interval_start(
  interval_ms: Int,
  last_start_wall_ms: Int?,
  armed: TimerClock,
  missed: Str,
) -> TimerDue {
  if let last = last_start_wall_ms {
    let elapsed = if armed.wall_ms > last { armed.wall_ms - last } else { 0 }
    if elapsed >= interval_ms {
      let occurrences = elapsed / interval_ms
      if missed == "skip" {
        return {
          kind: "skipped-missed",
          missed: occurrences,
          next_mono_ms: armed.mono_ms + interval_ms,
          next_wall_ms: 0,
          next_in_ms: interval_ms,
        }
      }
      return {kind: "coalesced-start", missed: occurrences - 1, next_mono_ms: armed.mono_ms, next_wall_ms: 0, next_in_ms: 0}
    }
    let remaining = interval_ms - elapsed
    return {kind: "wait", missed: 0, next_mono_ms: armed.mono_ms + remaining, next_wall_ms: 0, next_in_ms: remaining}
  }
  {
    kind: "wait",
    missed: 0,
    next_mono_ms: armed.mono_ms + interval_ms,
    next_wall_ms: 0,
    next_in_ms: interval_ms,
  }
}

## The calendar decision when the scheduler arms, from the persisted anchor.
export pure timer_calendar_start(
  hour: Int,
  minute: Int,
  next_wall_ms: Int?,
  armed: TimerClock,
  missed: Str,
) -> TimerDue {
  if let anchored = next_wall_ms {
    return timer_calendar_due(hour, minute, anchored, armed.wall_ms, missed)
  }
  let following = timer_calendar_next(hour, minute, armed.wall_ms)
  {
    kind: "wait",
    missed: 0,
    next_mono_ms: 0,
    next_wall_ms: following,
    next_in_ms: following - armed.wall_ms,
  }
}

## The arming decision for one job.
export pure timer_startup_due(job: TimerJob, state: TimerState, armed: TimerClock) -> TimerDue {
  if job.schedule == "calendar" {
    timer_calendar_start(job.hour, job.minute, state.calendar_next_wall_ms, armed, job.missed)
  } else {
    timer_interval_start(job.every_ms, state.last_start_wall_ms, armed, job.missed)
  }
}

## Classify one observed gap between adjacent scheduler passes. A gap where both
## clocks advanced together is a freeze such as a VM pause; a wall-only gap is a
## wall correction.
export pure timer_resume_kind(wall_delta_ms: Int, mono_delta_ms: Int, tolerance_ms: Int) -> Str {
  let mono = if mono_delta_ms < 0 { 0 } else { mono_delta_ms }
  let drift = wall_delta_ms - mono
  if drift > tolerance_ms {
    "wall-forward"
  } else if drift < -tolerance_ms {
    "wall-backward"
  } else if mono > tolerance_ms {
    "gap"
  } else {
    "steady"
  }
}

## The overlap policy for a due occurrence of a job that may still be running.
export pure timer_overlap_action(policy: Str, running: Bool, queued: Bool) -> Str {
  if ! running {
    return "start"
  }
  if policy == "skip" {
    return "skip"
  }
  if queued {
    return "skip"
  }
  "queue"
}

## The cancellation outcome for one job.
export pure timer_cancel_action(cancelled: Bool, running: Bool, queued: Bool) -> Str {
  if ! cancelled {
    return "active"
  }
  if running {
    return "terminate"
  }
  if queued {
    return "drop"
  }
  "hold"
}

## The retry delay after a failed attempt, or null when the bounded retries are spent.
export pure timer_retry_delay(attempt: Int, retries: Int, delay_ms: Int) -> Int? {
  if attempt <= retries { delay_ms } else { null }
}

## The durable outcome of one finished run.
export pure timer_outcome(exit_code: Int, signaled: Bool, timed_out: Bool) -> Str {
  if timed_out {
    return "timeout"
  }
  if signaled {
    return "signaled"
  }
  if exit_code == 0 { "ok" } else { "failed" }
}

## The result of a run that was still running when the scheduler armed.
export pure timer_interrupted(state: TimerState) -> TimerState {
  if state.last_outcome == "running" {
    return {
      name: state.name,
      last_start_wall_ms: state.last_start_wall_ms,
      last_finish_wall_ms: null,
      last_outcome: "interrupted",
      last_exit_code: null,
      runs: state.runs,
      failures: state.failures,
      coalesced: state.coalesced,
      skipped_missed: state.skipped_missed,
      skipped_overlap: state.skipped_overlap,
      queued: state.queued,
      cancelled: state.cancelled,
      calendar_next_wall_ms: state.calendar_next_wall_ms,
    }
  }
  state
}

## A fresh durable record for one job.
export pure timer_state_new(name: Str) -> TimerState {
  {
    name: name,
    last_start_wall_ms: null,
    last_finish_wall_ms: null,
    last_outcome: "never",
    last_exit_code: null,
    runs: 0,
    failures: 0,
    coalesced: 0,
    skipped_missed: 0,
    skipped_overlap: 0,
    queued: 0,
    cancelled: 0,
    calendar_next_wall_ms: null,
  }
}

## The durable record after one run starts.
export pure timer_state_started(previous: TimerState, wall_ms: Int) -> TimerState {
  {
    name: previous.name,
    last_start_wall_ms: wall_ms,
    last_finish_wall_ms: null,
    last_outcome: "running",
    last_exit_code: null,
    runs: previous.runs + 1,
    failures: previous.failures,
    coalesced: previous.coalesced,
    skipped_missed: previous.skipped_missed,
    skipped_overlap: previous.skipped_overlap,
    queued: previous.queued,
    cancelled: previous.cancelled,
    calendar_next_wall_ms: previous.calendar_next_wall_ms,
  }
}

## The durable record after one run finishes.
export pure timer_state_finished(previous: TimerState, wall_ms: Int, outcome: Str, exit_code: Int?) -> TimerState {
  {
    name: previous.name,
    last_start_wall_ms: previous.last_start_wall_ms,
    last_finish_wall_ms: wall_ms,
    last_outcome: outcome,
    last_exit_code: exit_code,
    runs: previous.runs,
    failures: if outcome == "ok" or outcome == "cancelled" { previous.failures } else { previous.failures + 1 },
    coalesced: previous.coalesced,
    skipped_missed: previous.skipped_missed,
    skipped_overlap: previous.skipped_overlap,
    queued: previous.queued,
    cancelled: previous.cancelled,
    calendar_next_wall_ms: previous.calendar_next_wall_ms,
  }
}

## The durable record with one counter advanced.
export pure timer_state_counted(
  previous: TimerState,
  coalesced: Int,
  skipped_missed: Int,
  skipped_overlap: Int,
  queued: Int,
  cancelled: Int,
) -> TimerState {
  {
    name: previous.name,
    last_start_wall_ms: previous.last_start_wall_ms,
    last_finish_wall_ms: previous.last_finish_wall_ms,
    last_outcome: previous.last_outcome,
    last_exit_code: previous.last_exit_code,
    runs: previous.runs,
    failures: previous.failures,
    coalesced: previous.coalesced + coalesced,
    skipped_missed: previous.skipped_missed + skipped_missed,
    skipped_overlap: previous.skipped_overlap + skipped_overlap,
    queued: previous.queued + queued,
    cancelled: previous.cancelled + cancelled,
    calendar_next_wall_ms: previous.calendar_next_wall_ms,
  }
}

## The durable record with its calendar anchor replaced.
export pure timer_state_anchored(previous: TimerState, next_wall_ms: Int?) -> TimerState {
  {
    name: previous.name,
    last_start_wall_ms: previous.last_start_wall_ms,
    last_finish_wall_ms: previous.last_finish_wall_ms,
    last_outcome: previous.last_outcome,
    last_exit_code: previous.last_exit_code,
    runs: previous.runs,
    failures: previous.failures,
    coalesced: previous.coalesced,
    skipped_missed: previous.skipped_missed,
    skipped_overlap: previous.skipped_overlap,
    queued: previous.queued,
    cancelled: previous.cancelled,
    calendar_next_wall_ms: next_wall_ms,
  }
}

pure timer_json_str(value: Any, json_path: List[Any], fallback: Str) -> Str {
  json.get(value, json_path, fallback).require(Str) ?? fallback
}

pure timer_json_int(value: Any, json_path: List[Any], label: Str) -> Result[Int, Error] {
  match json.get(value, json_path, null).require(Int) {
    Ok(number) => Ok(number)
    Err(_) => Err(error.failure(f"{label} must be an integer"))
  }
}

pure timer_json_int_or(value: Any, json_path: List[Any], fallback: Int, label: Str) -> Result[Int, Error] {
  let raw = json.get(value, json_path, null)
  if raw == null {
    return Ok(fallback)
  }
  match raw.require(Int) {
    Ok(number) => Ok(number)
    Err(_) => Err(error.failure(f"{label} must be an integer"))
  }
}

## The definition named `name`, or null.
export pure timer_find_job(jobs: List[TimerJob], name: Str) -> TimerJob? {
  for job in jobs {
    if job.name == name {
      return job
    }
  }
  null
}

pure timer_is_running(running: List[TimerRunning], name: Str) -> Bool {
  for entry in running {
    if entry.name == name {
      return true
    }
  }
  false
}

pure timer_unknown_keys(value: Any, allowed: List[Str]) -> List[Str] {
  let record = value.require(Record) ?? {}
  [key for key in record.keys() if ! (key in allowed)]
}

## Validate and decode one job definition. `stem` is the file name without `.json`.
export pure timer_job_from_json(stem: Str, value: Any) -> Result[TimerJob, Error] {
  let unknown = timer_unknown_keys(value, ["format", "name", "schedule", "command", "timeout_ms", "overlap", "missed", "retries"])
  guard unknown.is_empty() else {
    return Err(error.failure(f"unknown keys: {unknown.join(",")}"))
  }
  let format = timer_json_str(value, ["format"], "")
  guard format == TIMER_JOB_FORMAT else {
    return Err(error.failure(f"format must be {TIMER_JOB_FORMAT}"))
  }
  let name = timer_json_str(value, ["name"], "")
  guard timer_name_ok(name) else {
    return Err(error.failure("name must match [A-Za-z0-9][A-Za-z0-9_.-]{0,63}"))
  }
  guard name == stem else {
    return Err(error.failure(f"name must match the file name {stem}.json"))
  }
  let schedule = json.get(value, ["schedule"], {}).require(Record) ?? {}
  let kind = timer_json_str(schedule, ["kind"], "")
  var every_ms = 0
  var hour = 0
  var minute = 0
  if kind == "interval" {
    let extras = timer_unknown_keys(schedule, ["kind", "every_ms"])
    guard extras.is_empty() else {
      return Err(error.failure(f"unknown schedule keys: {extras.join(",")}"))
    }
    every_ms = timer_json_int(schedule, ["every_ms"], "schedule.every_ms")?
    guard every_ms >= TIMER_MIN_INTERVAL_MS and every_ms <= TIMER_MAX_INTERVAL_MS else {
      return Err(error.failure(f"schedule.every_ms must be {TIMER_MIN_INTERVAL_MS}..{TIMER_MAX_INTERVAL_MS}"))
    }
  } else if kind == "calendar" {
    let extras = timer_unknown_keys(schedule, ["kind", "hour", "minute"])
    guard extras.is_empty() else {
      return Err(error.failure(f"unknown schedule keys: {extras.join(",")}"))
    }
    hour = timer_json_int(schedule, ["hour"], "schedule.hour")?
    minute = timer_json_int(schedule, ["minute"], "schedule.minute")?
    guard hour >= 0 and hour <= 23 and minute >= 0 and minute <= 59 else {
      return Err(error.failure("schedule.hour must be 0..23 and schedule.minute 0..59"))
    }
  } else {
    return Err(error.failure("schedule.kind must be interval or calendar"))
  }
  let argv = json.get(value, ["command"], []).require(List[Str]) ?? []
  guard ! argv.is_empty() and argv.len() <= TIMER_MAX_ARGV else {
    return Err(error.failure(f"command must hold 1..{TIMER_MAX_ARGV} arguments"))
  }
  guard argv[0].starts_with("/") else {
    return Err(error.failure("command[0] must be an absolute path"))
  }
  let timeout_ms = timer_json_int_or(value, ["timeout_ms"], 0, "timeout_ms")?
  guard timeout_ms >= 0 and timeout_ms <= TIMER_MAX_TIMEOUT_MS else {
    return Err(error.failure(f"timeout_ms must be 0..{TIMER_MAX_TIMEOUT_MS}"))
  }
  let overlap = timer_json_str(value, ["overlap"], "")
  guard overlap == "skip" or overlap == "queue" else {
    return Err(error.failure("overlap must be skip or queue"))
  }
  let missed = timer_json_str(value, ["missed"], "coalesce")
  guard missed == "coalesce" or missed == "skip" else {
    return Err(error.failure("missed must be coalesce or skip"))
  }
  let retries_value = json.get(value, ["retries"], {}).require(Record) ?? {}
  let extras = timer_unknown_keys(retries_value, ["max", "delay_ms"])
  guard extras.is_empty() else {
    return Err(error.failure(f"unknown retries keys: {extras.join(",")}"))
  }
  let retries = timer_json_int_or(retries_value, ["max"], 0, "retries.max")?
  let retry_delay_ms = timer_json_int_or(retries_value, ["delay_ms"], 0, "retries.delay_ms")?
  guard retries >= 0 and retries <= TIMER_MAX_RETRIES else {
    return Err(error.failure(f"retries.max must be 0..{TIMER_MAX_RETRIES}"))
  }
  guard retry_delay_ms >= 0 and retry_delay_ms <= TIMER_MAX_RETRY_DELAY_MS else {
    return Err(error.failure(f"retries.delay_ms must be 0..{TIMER_MAX_RETRY_DELAY_MS}"))
  }
  Ok({
    name: name,
    file: f"{stem}.json",
    schedule: kind,
    every_ms: every_ms,
    hour: hour,
    minute: minute,
    argv: argv,
    timeout_ms: timeout_ms,
    overlap: overlap,
    missed: missed,
    retries: retries,
    retry_delay_ms: retry_delay_ms,
  })
}

## Decode one persisted job record.
export pure timer_state_from_json(value: Any) -> Result[TimerState, Error] {
  let name = json.get(value, ["name"], "").require(Str)?
  guard timer_name_ok(name) else {
    return Err(error.failure("state entry has an invalid job name"))
  }
  let last_start_wall_ms = json.get(value, ["last_start_wall_ms"], null).require(Int?)?
  let last_finish_wall_ms = json.get(value, ["last_finish_wall_ms"], null).require(Int?)?
  let last_outcome = json.get(value, ["last_outcome"], "").require(Str)?
  let last_exit_code = json.get(value, ["last_exit_code"], null).require(Int?)?
  let runs = json.get(value, ["runs"], 0).require(Int)?
  let failures = json.get(value, ["failures"], 0).require(Int)?
  let coalesced = json.get(value, ["coalesced"], 0).require(Int)?
  let skipped_missed = json.get(value, ["skipped_missed"], 0).require(Int)?
  let skipped_overlap = json.get(value, ["skipped_overlap"], 0).require(Int)?
  let queued = json.get(value, ["queued"], 0).require(Int)?
  let cancelled = json.get(value, ["cancelled"], 0).require(Int)?
  let calendar_next_wall_ms = json.get(value, ["calendar_next_wall_ms"], null).require(Int?)?
  Ok({
    name: name,
    last_start_wall_ms: last_start_wall_ms,
    last_finish_wall_ms: last_finish_wall_ms,
    last_outcome: last_outcome,
    last_exit_code: last_exit_code,
    runs: runs,
    failures: failures,
    coalesced: coalesced,
    skipped_missed: skipped_missed,
    skipped_overlap: skipped_overlap,
    queued: queued,
    cancelled: cancelled,
    calendar_next_wall_ms: calendar_next_wall_ms,
  })
}

## Whether the recorded writer group is `gone` or may still be `alive`. A differing
## boot proves every process died; a live group whose leader pid now has another
## start time is a recycled id; a live group without its leader holds orphans.
export pure timer_writer_verdict(
  record_boot_id: Str,
  boot_id: Str,
  group_present: Bool,
  leader_start_ms: Int,
  recorded_start_ms: Int,
) -> Str {
  if record_boot_id != "" and boot_id != "" and record_boot_id != boot_id {
    return "gone"
  }
  if ! group_present {
    return "gone"
  }
  if leader_start_ms > 0 and recorded_start_ms > 0 and leader_start_ms != recorded_start_ms {
    return "gone"
  }
  "alive"
}

## Decode one writer record, refusing anything this scheduler did not write.
export pure timer_writer_from_json(value: Any) -> Result[TimerWriter, Error] {
  let format = json.get(value, ["format"], "").require(Str)?
  guard format == TIMER_WRITER_FORMAT else {
    return Err(error.failure(f"unsupported writer record format {format}"))
  }
  let name = json.get(value, ["name"], "").require(Str)?
  guard timer_name_ok(name) else {
    return Err(error.failure("writer record has an invalid job name"))
  }
  let pid = json.get(value, ["pid"], 0).require(Int)?
  guard pid > 1 else {
    return Err(error.failure(f"writer record for {name} has an invalid process id"))
  }
  Ok({
    name: name,
    attempt: json.get(value, ["attempt"], 0).require(Int)?,
    boot_id: json.get(value, ["boot_id"], "").require(Str)?,
    pid: pid,
    start_time_ms: json.get(value, ["start_time_ms"], 0).require(Int)?,
    started_wall_ms: json.get(value, ["started_wall_ms"], 0).require(Int)?,
  })
}

## Whether a job's release is due: `run`, `wait` for its retry delay, or `exhausted` after the
## published number of failed attempts.
export pure timer_release_due(release: TimerRelease, now_mono_ms: Int, max_attempts: Int) -> Str {
  if release.attempts >= max_attempts {
    return "exhausted"
  }
  if now_mono_ms < release.due_mono_ms {
    return "wait"
  }
  "run"
}

## The bookkeeping after one release attempt.
export pure timer_release_after(release: TimerRelease, now_mono_ms: Int, retry_delay_ms: Int, counted: Bool) -> TimerRelease {
  {
    due_mono_ms: now_mono_ms + retry_delay_ms,
    attempts: if counted { release.attempts + 1 } else { release.attempts },
    reported: release.reported,
  }
}

## The longest one release command may run for a record naming `services` services.
export pure timer_release_cap_ms(policy: TimerReleasePolicy) -> Int {
  policy.release_timeout_ms * (if policy.services > 0 { policy.services } else { 1 }) + TIMER_RELEASE_MARGIN_MS
}

pure timer_options(argv: List[Str]) -> Result[TimerOptions, Str] {
  var options = TimerOptions(
    action: "run",
    name: "",
    job_dir: TIMER_JOB_DIR.display(),
    state_dir: TIMER_STATE_DIR.display(),
    run_dir: TIMER_RUN_DIR.display(),
    json: false,
    help: false,
  )
  var index = 0
  var saw_action = false
  while index < argv.len() {
    let word = argv[index]
    index += 1
    if word == "--help" or word == "-h" or word == "help" {
      options.help = true
      continue
    }
    if word == "--json" {
      options.json = true
      continue
    }
    if word == "--jobs" or word == "--state" or word == "--run-dir" {
      guard index < argv.len() else {
        return Err(f"{word} requires a directory")
      }
      let value = argv[index]
      index += 1
      guard value.starts_with("/") else {
        return Err(f"{word} requires an absolute path")
      }
      if word == "--jobs" {
        options.job_dir = value
      } else if word == "--state" {
        options.state_dir = value
      } else {
        options.run_dir = value
      }
      continue
    }
    if word.starts_with("-") {
      return Err(f"unknown option {word}")
    }
    if options.action == "run" and ! saw_action {
      guard word in ["run", "status", "cancel", "resume", "run-now"] else {
        return Err(f"unknown action {word}")
      }
      options.action = word
      saw_action = true
      continue
    }
    if options.action == "cancel" or options.action == "resume" or options.action == "run-now" {
      guard options.name == "" and timer_name_ok(word) else {
        return Err("cancel, resume, and run-now take exactly one valid job name")
      }
      options.name = word
      continue
    }
    return Err(f"unexpected argument {word}")
  }
  if options.action == "cancel" or options.action == "resume" or options.action == "run-now" {
    guard options.name != "" else {
      return Err(f"{options.action} requires a job name")
    }
  }
  Ok(options)
}

proc timer_read_boot_id() [fs] -> Str {
  match p"/proc/sys/kernel/random/boot_id".read_text() {
    Ok(text) => text.trim()
    Err(_) => ""
  }
}

proc timer_read_clock() [time, error] -> Result[TimerClock, Error] {
  let mono = monotonic.now()?
  {mono_ms: mono.ms, wall_ms: time.now()}
}

proc timer_log(line: Str) [io, error] -> Result[Unit, Error] {
  print $line
  io.flush_stdout()
}

## Read and validate every job definition in `dir`, sorted by name.
export proc timer_load_jobs(dir: Path) [fs, error] -> Result[TimerJobs, Error] {
  var jobs: List[TimerJob] = []
  var problems: List[TimerProblem] = []
  return {jobs: jobs, problems: problems} unless dir.exists()
  var seen: Map[Bool] = {}
  var entries = fs.children(dir)? |> where .kind == "file" |> where .name.ends_with(".json") |> collect
  entries = entries |> sort-by .name |> collect
  for entry in entries {
    let stem = entry.name[..entry.name.byte_len() - 5]
    if jobs.len() >= TIMER_MAX_JOBS {
      problems += [{name: stem, file: entry.name, message: f"more than {TIMER_MAX_JOBS} definitions"}]
      continue
    }
    let decoded = match json.read(entry.path) {
      Ok(value) => timer_job_from_json(stem, value),
      Err(problem) => Err(error.failure(f"decode: {problem.message}")),
    }
    match decoded {
      Ok(job) => {
        if seen.get(job.name) ?? false {
          problems += [{name: job.name, file: job.file, message: "duplicate job name"}]
          continue
        }
        seen[job.name] = true
        jobs += [job]
      }
      Err(problem) => {
        problems += [{name: stem, file: entry.name, message: problem.message}]
      }
    }
  }
  {jobs: jobs, problems: problems}
}

## Read the durable state file. A damaged file fails rather than silently resetting schedules.
export proc timer_load_state(file: Path) [fs, error] -> Result[Map[TimerState], Error] {
  var states: Map[TimerState] = {}
  return states unless file.exists()
  let value = json.read(file)?
  let format = json.get(value, ["format"], "").require(Str)?
  guard format == TIMER_STATE_FORMAT else {
    return Err(error.failure(f"unsupported timer state format in {file.display()}"))
  }
  let entries = json.get(value, ["jobs"], []).require(List[Any])?
  for entry in entries {
    let state = timer_state_from_json(entry)?
    guard ! (state.name in states.keys()) else {
      return Err(error.failure(f"duplicate timer state entry {state.name}"))
    }
    states[state.name] = state
  }
  states
}

## Durably replace the state file.
export proc timer_save_state(file: Path, jobs: List[TimerJob], states: Map[TimerState]) [fs, error] -> Result[Unit, Error] {
  let entries = collect {
    for job in jobs {
      let state = states.get(job.name) ?? timer_state_new(job.name)
      yield state
    }
  }
  let body = json.encode({format: TIMER_STATE_FORMAT, jobs: entries})? + "\n"
  match file.parent().mkdir() {
    Ok(_) => {}
    Err(problem) => {
      guard problem.errno == 17 else {
        return Err(problem)
      }
    }
  }
  atomically replace file as next {
    next.write(body, mode: 0o644)
    fs.fsync(next)
  }
  fs.fsync(file.parent())
}

## Read the cancellation markers. The file names are the contract; contents are ignored.
export proc timer_load_cancels(dir: Path) [fs, error] -> Result[Set[Str], Error] {
  var cancelled: Set[Str] = set.empty()
  return cancelled unless dir.exists()
  for entry in fs.children(dir)? {
    continue unless entry.kind == "file"
    continue unless timer_name_ok(entry.name)
    cancelled = cancelled.add(entry.name)
  }
  cancelled
}

proc timer_write_cancel(dir: Path, name: Str, active: Bool) [fs, error] -> Result[Unit, Error] {
  let marker = fp"{dir}/{name}"
  if active {
    dir.mkdir(parents: true)?
    atomically replace marker as next {
      next.write("cancelled\n", mode: 0o644)
      fs.fsync(next)
    }
    fs.fsync(dir)
  } else {
    marker.remove(missing_ok: true)?
    fs.fsync(dir)
  }
}

pure timer_derive_views(jobs: List[TimerJob], states: Map[TimerState], cancelled: Set[Str], now: TimerClock) -> Map[TimerView] {
  var views: Map[TimerView] = {}
  for job in jobs {
    if job.name in cancelled {
      views[job.name] = TimerView(state: "cancelled", next_wall_ms: null, next_in_ms: 0, next_source: "cancelled", retry_attempt: 0, retry_in_ms: 0)
      continue
    }
    let state = states.get(job.name) ?? timer_state_new(job.name)
    let due = timer_startup_due(job, state, now)
    let scheduled = due.kind == "coalesced-start"
    let next_wall = if job.schedule == "calendar" { due.next_wall_ms } else { now.wall_ms + due.next_in_ms }
    views[job.name] = {
      state: if scheduled { "due" } else { "idle" },
      next_wall_ms: next_wall,
      next_in_ms: due.next_in_ms,
      next_source: "startup",
      retry_attempt: 0,
      retry_in_ms: 0,
    }
  }
  views
}

pure timer_live_views(value: Any) -> Map[TimerView] {
  var views: Map[TimerView] = {}
  let entries = json.get(value, ["jobs"], []).require(List[Any]) ?? []
  for entry in entries {
    let name = json.get(entry, ["name"], "").require(Str) ?? ""
    continue when name == ""
    views[name] = {
      state: timer_json_str(entry, ["state"], "unknown"),
      next_wall_ms: json.get(entry, ["next", "wall_ms"], null).require(Int?) ?? null,
      next_in_ms: json.get(entry, ["next", "in_ms"], 0).require(Int) ?? 0,
      next_source: timer_json_str(entry, ["next", "source"], ""),
      retry_attempt: json.get(entry, ["retry", "attempt"], 0).require(Int) ?? 0,
      retry_in_ms: json.get(entry, ["retry", "in_ms"], 0).require(Int) ?? 0,
    }
  }
  views
}

pure timer_status_job(job: TimerJob, state: TimerState, view: TimerView) -> TimerStatusJob {
  {
    name: job.name,
    file: job.file,
    schedule: job.schedule,
    every_ms: job.every_ms,
    hour: job.hour,
    minute: job.minute,
    overlap: job.overlap,
    missed: job.missed,
    retries: job.retries,
    state: view.state,
    next: {wall_ms: view.next_wall_ms, in_ms: view.next_in_ms, source: view.next_source},
    last: {
      start_wall_ms: state.last_start_wall_ms,
      finish_wall_ms: state.last_finish_wall_ms,
      outcome: state.last_outcome,
      exit_code: state.last_exit_code,
    },
    retry: {attempt: view.retry_attempt, in_ms: view.retry_in_ms},
    counts: {
      runs: state.runs,
      failures: state.failures,
      coalesced: state.coalesced,
      skipped_missed: state.skipped_missed,
      skipped_overlap: state.skipped_overlap,
      queued: state.queued,
      cancelled: state.cancelled,
    },
    cancelled: view.state == "cancelled",
  }
}

## Build the normalized inspection snapshot from definitions, durable state and live views.
export proc timer_snapshot(
  jobs: List[TimerJob],
  problems: List[TimerProblem],
  states: Map[TimerState],
  views: Map[TimerView],
  now: TimerClock,
  armed_wall_ms: Int,
  scheduler_pid: Int,
  boot_id: Str,
  resume: Str,
  last_step: TimerStep?,
) [error] -> Result[TimerStatus, Error] {
  let entries = collect {
    for job in jobs {
      let state = states.get(job.name) ?? timer_state_new(job.name)
      let view = views.get(job.name) ?? TimerView(state: "unknown", next_wall_ms: null, next_in_ms: 0, next_source: "", retry_attempt: 0, retry_in_ms: 0)
      yield timer_status_job(job, state, view)
    }
  }
  {
    format: TIMER_STATUS_FORMAT,
    scheduler_pid: scheduler_pid,
    boot_id: boot_id,
    armed_wall_ms: armed_wall_ms,
    sampled_wall_ms: now.wall_ms,
    resume: resume,
    last_step: last_step,
    jobs: entries,
    invalid: problems,
  }
}

proc timer_format_wall(value: Int?) [time] -> Str {
  if let wall = value {
    if wall > 0 {
      return time.format(wall * 1000000, "%Y-%m-%dT%H:%M:%SZ", utc: true) ?? f"{wall}ms"
    }
  }
  "-"
}

## Print one human status report, or the normalized snapshot as one JSON line.
export proc timer_print_status(snapshot: TimerStatus, as_json: Bool) [io, time, error] -> Result[Unit, Error] {
  if as_json {
    print json.encode(snapshot)?
    return
  }
  let scheduler = if snapshot.scheduler_pid > 0 { "running" } else { "down" }
  print f"laputa-timers format={snapshot.format} scheduler={scheduler} pid={snapshot.scheduler_pid} jobs={snapshot.jobs.len()} invalid={snapshot.invalid.len()} resume={snapshot.resume} sampled={timer_format_wall(snapshot.sampled_wall_ms)}"
  for job in snapshot.jobs {
    let schedule = if job.schedule == "calendar" {
      f"calendar@{job.hour:>2}:{job.minute:>2}"
    } else {
      f"interval/{job.every_ms}ms"
    }
    let next = if job.next.wall_ms != null {
      f"{timer_format_wall(job.next.wall_ms)} in={job.next.in_ms}ms source={job.next.source}"
    } else {
      "none"
    }
    let retry_text = if job.retry.in_ms > 0 { f" retry_attempt={job.retry.attempt} retry_in={job.retry.in_ms}ms" } else { "" }
    print f"job {job.name} schedule={schedule} state={job.state} last={job.last.outcome}@{timer_format_wall(job.last.start_wall_ms)} next={next}{retry_text} runs={job.counts.runs} failures={job.counts.failures} coalesced={job.counts.coalesced} skipped={job.counts.skipped_missed}/{job.counts.skipped_overlap} queued={job.counts.queued} cancelled={job.counts.cancelled}"
  }
  for problem in snapshot.invalid {
    print f"invalid {problem.name} file={problem.file} message={problem.message}"
  }
}

proc timer_writer_file(store: TimerWriterStore, name: Str) -> Path {
  fp"{store.dir}/{name}.json"
}

## The kernel start time of a live process in milliseconds, or 0 when it is not listed.
export proc timer_process_start_ms(pid: Int) [process, error] -> Result[Int, Error] {
  for entry in process.list()? {
    if entry.pid == pid {
      return Ok(entry.start_time_ms)
    }
  }
  Ok(0)
}

## Durably record one attempt's writer identity, replacing any previous record of the job.
export proc timer_writer_save(store: TimerWriterStore, record: TimerWriter) [fs, error] -> Result[Unit, Error] {
  store.dir.mkdir(parents: true)?
  let file = timer_writer_file(store, record.name)
  let body = json.encode({
    format: TIMER_WRITER_FORMAT,
    name: record.name,
    attempt: record.attempt,
    boot_id: record.boot_id,
    pid: record.pid,
    start_time_ms: record.start_time_ms,
    started_wall_ms: record.started_wall_ms,
  })? + "\n"
  atomically replace file as next {
    next.write(body, mode: 0o600)
    fs.fsync(next)
  }
  fs.fsync(store.dir)
}

## The names with a writer record, in file-name order.
export proc timer_writer_names(store: TimerWriterStore) [fs, error] -> Result[List[Str], Error] {
  if ! store.dir.exists() {
    return Ok([])
  }
  let names = collect {
    for entry in fs.children(store.dir)? |> sort-by .name {
      if entry.name.ends_with(".json") {
        yield entry.name.byte_slice(0, entry.name.byte_len() - 5)
      }
    }
  }
  Ok(names)
}

type TimerWriterScan = {verdict: Str, groups: List[Int]}

proc timer_writer_observe(record: TimerWriter, boot_id: Str) [process, error] -> Result[TimerWriterScan, Error] {
  var leader = 0
  var groups: List[Int] = []
  for entry in process.list()? {
    if entry.pid == record.pid {
      leader = entry.start_time_ms
    }
    let pgid = entry.pgrp ?? 0
    if (entry.session ?? 0) == record.pid and pgid > 1 and ! entry.status.starts_with("Z") {
      if ! (pgid in groups) {
        groups += [pgid]
      }
    }
  }
  let verdict = timer_writer_verdict(record.boot_id, boot_id, ! groups.is_empty(), leader, record.start_time_ms)
  Ok({verdict: verdict, groups: if verdict == "gone" { [] } else { groups }})
}

proc timer_writer_signal(groups: List[Int], signal: Str) [process, error] -> Result[Unit, Error] {
  for pgid in groups {
    match process.kill_group(pgid, signal) {
      Ok(_) => {}
      Err(problem) => {
        guard problem.errno == 3 else {
          return Err(problem)
        }
      }
    }
  }
  Ok()
}

proc timer_writer_wait_gone(record: TimerWriter, boot_id: Str, resend: Str, limit_ms: Int) [process, time, error] -> Result[Bool, Error] {
  var waited = 0
  while true {
    let scan = timer_writer_observe(record, boot_id)?
    if scan.verdict == "gone" {
      return Ok(true)
    }
    if resend != "" {
      timer_writer_signal(scan.groups, resend)?
    }
    guard waited < limit_ms else {
      return Ok(false)
    }
    time.sleep(50ms)?
    waited += 50
  }
  Ok(false)
}

## Stop whatever is left of the recorded writer and report `gone` (nothing was left),
## `stopped` (this call ended the last member) or `alive` (not proven stopped). The writer is
## the attempt's whole session: a snapshot tool the job started in its own process group
## is still a member.
export proc timer_writer_stop(record: TimerWriter, boot_id: Str) [process, time, error] -> Result[Str, Error] {
  let scan = timer_writer_observe(record, boot_id)?
  if scan.verdict == "gone" {
    return Ok("gone")
  }
  timer_writer_signal(scan.groups, "TERM")?
  if timer_writer_wait_gone(record, boot_id, "", TIMER_KILL_GRACE_MS)? {
    return Ok("stopped")
  }
  if timer_writer_wait_gone(record, boot_id, "KILL", TIMER_KILL_GRACE_MS)? {
    return Ok("stopped")
  }
  Ok("alive")
}

## Prove the named job's recorded writer stopped, then retire its record. Returns
## `none` (no record), `settled`, or `unproven`, which keeps the record for the next try.
export proc timer_writer_settle(store: TimerWriterStore, name: Str) [fs, process, time, io, error] -> Result[Str, Error] {
  let file = timer_writer_file(store, name)
  if ! file.exists() {
    return Ok("none")
  }
  let record = timer_writer_from_json(json.read(file)?)?
  let outcome = match timer_writer_stop(record, store.boot_id) {
    Ok(result) => result
    Err(problem) => {
      timer_log(f"event=writer-error name={name} pid={record.pid} message={problem.message}")?
      "alive"
    }
  }
  if outcome == "alive" {
    timer_log(f"event=writer-unproven name={name} attempt={record.attempt} pid={record.pid}")?
    return Ok("unproven")
  }
  file.remove(missing_ok: true)?
  fs.fsync(store.dir)
  timer_log(f"event=writer-settled name={name} attempt={record.attempt} pid={record.pid} result={outcome}")?
  Ok("settled")
}

## The jobs with a quiescence record, in file-name order.
export proc timer_quiesce_names(store: TimerWriterStore) [fs, error] -> Result[List[Str], Error] {
  if ! store.quiesce_dir.exists() {
    return Ok([])
  }
  let names = collect {
    for entry in fs.children(store.quiesce_dir)? |> sort-by .name {
      if entry.name.ends_with(".json") {
        yield entry.name.byte_slice(0, entry.name.byte_len() - 5)
      }
    }
  }
  Ok(names)
}

proc timer_release_policy(store: TimerWriterStore, name: Str) [fs, error] -> Result[TimerReleasePolicy, Error] {
  let value = json.read(fp"{store.quiesce_dir}/{name}.json")?
  let format = json.get(value, ["format"], "").require(Str)?
  guard format == "laputa-quiesce-1" else {
    return Err(error.failure(f"unsupported quiescence record format {format}"))
  }
  let timeout = json.get(value, ["release_timeout_ms"], 60000).require(Int)?
  let delay = json.get(value, ["retry_delay_ms"], 30000).require(Int)?
  let attempts = json.get(value, ["max_attempts"], 5).require(Int)?
  let services = json.get(value, ["services"], []).require(List[Any])?
  guard timeout >= 1 and timeout <= TIMER_MAX_RETRY_DELAY_MS and delay >= 1 and delay <= TIMER_MAX_RETRY_DELAY_MS and attempts >= 1 and attempts <= 20 else {
    return Err(error.failure(f"quiescence record of {name} has out-of-range release bounds"))
  }
  Ok({release_timeout_ms: timeout, retry_delay_ms: delay, max_attempts: attempts, services: services.len()})
}

proc timer_release_run(command: List[Str], name: Str, policy: TimerReleasePolicy) [process, error] -> Result[Bool, Error] {
  match process.run(process.command_argv(
    command[0],
    command + [name],
    cwd: p"/",
    stdin: p"/dev/null",
    timeout: time.millis(timer_release_cap_ms(policy)),
  )) {
    Ok(status) => Ok(status.ok)
    Err(_) => Ok(false)
  }
}

## Release the quiescence of every job that has no live attempt, once its writer is proven
## stopped. A failed release keeps the record and is retried after the record's own delay, up
## to its attempt bound; an unproven writer delays without using an attempt.
export proc timer_quiesce_reconcile(
  store: TimerWriterStore,
  command: List[Str],
  running: List[TimerRunning],
  releases: Map[TimerRelease],
  now: TimerClock,
) [fs, process, time, io, error] -> Result[Map[TimerRelease], Error] {
  var out = releases
  let names = timer_quiesce_names(store)?
  for name in names {
    if timer_is_running(running, name) {
      continue
    }
    let tracker = out.get(name) ?? TimerRelease(due_mono_ms: 0, attempts: 0, reported: false)
    let policy = match timer_release_policy(store, name) {
      Ok(value) => value
      Err(problem) => {
        if ! tracker.reported {
          timer_log(f"event=quiesce-record-invalid name={name} message={problem.message}")?
          out[name] = TimerRelease(due_mono_ms: tracker.due_mono_ms, attempts: tracker.attempts, reported: true)
        }
        continue
      }
    }
    let decision = timer_release_due(tracker, now.mono_ms, policy.max_attempts)
    if decision == "wait" {
      continue
    }
    if decision == "exhausted" {
      if ! tracker.reported {
        timer_log(f"event=quiesce-release-exhausted name={name} attempts={tracker.attempts}")?
        out[name] = TimerRelease(due_mono_ms: tracker.due_mono_ms, attempts: tracker.attempts, reported: true)
      }
      continue
    }
    if timer_writer_settle(store, name)? == "unproven" {
      out[name] = timer_release_after(tracker, now.mono_ms, policy.retry_delay_ms, false)
      continue
    }
    if timer_release_run(command, name, policy)? and ! fp"{store.quiesce_dir}/{name}.json".exists()? {
      timer_log(f"event=quiesce-released name={name} attempts={tracker.attempts + 1}")?
      out = out.remove(name)
    } else {
      let next = timer_release_after(tracker, now.mono_ms, policy.retry_delay_ms, true)
      timer_log(f"event=quiesce-release-failed name={name} attempts={next.attempts} max={policy.max_attempts}")?
      out[name] = next
    }
  }
  Ok(out)
}

proc timer_launch(
  job: TimerJob,
  occurrence_wall_ms: Int,
  attempt: Int,
  missed: Int,
  now: TimerClock,
  store: TimerWriterStore,
) [fs, process, time, io, error] -> Result[TimerRunning, Error] {
  if timer_writer_settle(store, job.name)? == "unproven" {
    return Err(error.failure(f"the previous attempt of {job.name} is not proven stopped"))
  }
  if job.name in timer_quiesce_names(store)? {
    return Err(error.failure(f"the quiescence of the previous attempt of {job.name} is not released"))
  }
  var job_env: Map[Bytes] = {}
  job_env["LAPUTA_TIMER_NAME"] = bytes.from_text(job.name)
  job_env["LAPUTA_TIMER_ATTEMPT"] = bytes.from_text(f"{attempt}")
  job_env["LAPUTA_TIMER_MISSED"] = bytes.from_text(f"{missed}")
  job_env["LAPUTA_TIMER_SCHEDULED_WALL_MS"] = bytes.from_text(f"{occurrence_wall_ms}")
  job_env["LAPUTA_TIMER_START_WALL_MS"] = bytes.from_text(f"{now.wall_ms}")
  job_env["LAPUTA_TIMER_START_MONO_MS"] = bytes.from_text(f"{now.mono_ms}")
  let plan = process.command_argv(job.argv[0], job.argv, cwd: p"/", env: job_env, stdin: p"/dev/null", new_session: true)
  let handle = spawn plan?
  let record = TimerWriter(
    name: job.name,
    attempt: attempt,
    boot_id: store.boot_id,
    pid: handle.pid,
    start_time_ms: timer_process_start_ms(handle.pid) ?? 0,
    started_wall_ms: now.wall_ms,
  )
  match timer_writer_save(store, record) {
    Ok(_) => {}
    Err(problem) => {
      match process.kill_group(handle.pid, "KILL") {
        Ok(_) => {}
        Err(_) => {}
      }
      return Err(problem)
    }
  }
  let deadline = if job.timeout_ms > 0 { now.mono_ms + job.timeout_ms } else { 0 }
  Ok({
    name: job.name,
    handle: handle,
    deadline_mono_ms: deadline,
    occurrence_wall_ms: occurrence_wall_ms,
    attempt: attempt,
    missed: missed,
  })
}

proc timer_start(
  job: TimerJob,
  state: TimerState,
  runtime: TimerRuntime,
  occurrence_wall_ms: Int,
  attempt: Int,
  missed: Int,
  now: TimerClock,
  store: TimerWriterStore,
) [fs, process, time, io, error] -> Result[TimerStartOutcome, Error] {
  match timer_launch(job, occurrence_wall_ms, attempt, missed, now, store) {
    Ok(started) => Ok({started: started, state: timer_state_started(state, now.wall_ms), runtime: runtime})
    Err(problem) => {
      timer_log(f"event=job-spawn-error name={job.name} attempt={attempt} message={problem.message}")?
      var next = runtime
      if let delay_value = timer_retry_delay(attempt, job.retries, job.retry_delay_ms) {
        next.retry_attempt = attempt
        next.retry_missed = missed
        next.retry_wall_ms = occurrence_wall_ms
        next.retry_at_mono_ms = now.mono_ms + delay_value
      } else {
        next.retry_attempt = 0
        next.retry_at_mono_ms = 0
      }
      Ok({started: null, state: timer_state_finished(state, now.wall_ms, "failed", null), runtime: next})
    }
  }
}

proc timer_pid_alive(pid: Int) [process] -> Bool {
  if pid <= 0 {
    return false
  }
  match process.kill(pid, "0") {
    Ok(_) => true
    Err(_) => false,
  }
}

proc timers_status(config: SchedulerConfig, as_json: Bool) [fs, process, time, io, error] -> Result[Unit, Error] {
  let loaded = timer_load_jobs(config.job_dir)?
  let states = timer_load_state(fp"{config.state_dir}/{TIMER_STATE_NAME}")?
  let cancelled = timer_load_cancels(fp"{config.state_dir}/{TIMER_CANCEL_DIR}")?
  let now = timer_read_clock()?
  let boot_id = timer_read_boot_id()
  let status_path = fp"{config.run_dir}/{TIMER_STATUS_NAME}"
  var views: Map[TimerView] = {}
  var scheduler_pid = 0
  var armed_wall_ms = now.wall_ms
  var resume = "unknown"
  var last_step: TimerStep? = null
  if status_path.exists() {
    match json.read(status_path) {
      Ok(live) => {
        let live_pid = json.get(live, ["scheduler_pid"], 0).require(Int) ?? 0
        let live_boot = json.get(live, ["boot_id"], "").require(Str) ?? ""
        if timer_pid_alive(live_pid) and live_boot == boot_id and (json.get(live, ["format"], "").require(Str) ?? "") == TIMER_STATUS_FORMAT {
          scheduler_pid = live_pid
          armed_wall_ms = json.get(live, ["armed_wall_ms"], now.wall_ms).require(Int) ?? now.wall_ms
          resume = json.get(live, ["resume"], "unknown").require(Str) ?? "unknown"
          let step = json.get(live, ["last_step"], null)
          if step != null {
            last_step = TimerStep(
              kind: json.get(step, ["kind"], "").require(Str) ?? "",
              wall_delta_ms: json.get(step, ["wall_delta_ms"], 0).require(Int) ?? 0,
              mono_delta_ms: json.get(step, ["mono_delta_ms"], 0).require(Int) ?? 0,
              at_wall_ms: json.get(step, ["at_wall_ms"], 0).require(Int) ?? 0,
            )
          }
          views = timer_live_views(live)
        }
      }
      Err(_) => {}
    }
  }
  if views.is_empty() {
    views = timer_derive_views(loaded.jobs, states, cancelled, now)
  }
  let snapshot = timer_snapshot(loaded.jobs, loaded.problems, states, views, now, armed_wall_ms, scheduler_pid, boot_id, resume, last_step)?
  timer_print_status(snapshot, as_json)
}

pure timer_job_stub(name: Str) -> TimerJob {
  {
    name: name,
    file: "",
    schedule: "interval",
    every_ms: TIMER_MIN_INTERVAL_MS,
    hour: 0,
    minute: 0,
    argv: [],
    timeout_ms: 0,
    overlap: "skip",
    missed: "coalesce",
    retries: 0,
    retry_delay_ms: 0,
  }
}

proc timer_initial_runtime(job: TimerJob, state: TimerState, armed: TimerClock) -> TimerRuntime {
  let due = timer_startup_due(job, state, armed)
  let pending = due.kind == "coalesced-start"
  {
    next_mono_ms: due.next_mono_ms,
    next_wall_ms: due.next_wall_ms,
    running: false,
    pending_start: pending,
    pending_missed: due.missed,
    queued: false,
    queued_wall_ms: 0,
    retry_attempt: 0,
    retry_at_mono_ms: 0,
    retry_missed: 0,
    retry_wall_ms: 0,
  }
}

proc timer_due(job: TimerJob, runtime: TimerRuntime, now: TimerClock) -> TimerDue {
  if job.schedule == "calendar" {
    timer_calendar_due(job.hour, job.minute, runtime.next_wall_ms, now.wall_ms, job.missed)
  } else {
    timer_interval_due(job.every_ms, runtime.next_mono_ms, now.mono_ms, job.missed)
  }
}

proc timer_views(
  jobs: List[TimerJob],
  states: Map[TimerState],
  runtimes: Map[TimerRuntime],
  cancelled: Set[Str],
  now: TimerClock,
) -> Map[TimerView] {
  var views: Map[TimerView] = {}
  for job in jobs {
    let runtime = runtimes.get(job.name) ?? timer_initial_runtime(job, states.get(job.name) ?? timer_state_new(job.name), now)
    if job.name in cancelled {
      views[job.name] = TimerView(state: "cancelled", next_wall_ms: null, next_in_ms: 0, next_source: "cancelled", retry_attempt: 0, retry_in_ms: 0)
      continue
    }
    if runtime.retry_at_mono_ms > 0 {
      let wait_ms = if runtime.retry_at_mono_ms > now.mono_ms { runtime.retry_at_mono_ms - now.mono_ms } else { 0 }
      views[job.name] = TimerView(
        state: "retry",
        next_wall_ms: now.wall_ms + wait_ms,
        next_in_ms: wait_ms,
        next_source: "retry",
        retry_attempt: runtime.retry_attempt,
        retry_in_ms: wait_ms,
      )
      continue
    }
    if runtime.queued {
      let wait_ms = if runtime.queued_wall_ms > now.wall_ms { runtime.queued_wall_ms - now.wall_ms } else { 0 }
      views[job.name] = TimerView(
        state: "queued",
        next_wall_ms: runtime.queued_wall_ms,
        next_in_ms: wait_ms,
        next_source: "queued",
        retry_attempt: 0,
        retry_in_ms: 0,
      )
      continue
    }
    if runtime.running {
      if job.schedule == "calendar" {
        let wait_ms = if runtime.next_wall_ms > now.wall_ms { runtime.next_wall_ms - now.wall_ms } else { 0 }
        views[job.name] = TimerView(state: "running", next_wall_ms: runtime.next_wall_ms, next_in_ms: wait_ms, next_source: "calendar", retry_attempt: 0, retry_in_ms: 0)
      } else {
        let wait_ms = if runtime.next_mono_ms > now.mono_ms { runtime.next_mono_ms - now.mono_ms } else { 0 }
        views[job.name] = TimerView(state: "running", next_wall_ms: now.wall_ms + wait_ms, next_in_ms: wait_ms, next_source: "monotonic", retry_attempt: 0, retry_in_ms: 0)
      }
      continue
    }
    if runtime.pending_start {
      views[job.name] = TimerView(state: "due", next_wall_ms: now.wall_ms, next_in_ms: 0, next_source: "startup", retry_attempt: 0, retry_in_ms: 0)
      continue
    }
    if job.schedule == "calendar" {
      let wait_ms = if runtime.next_wall_ms > now.wall_ms { runtime.next_wall_ms - now.wall_ms } else { 0 }
      views[job.name] = TimerView(state: "idle", next_wall_ms: runtime.next_wall_ms, next_in_ms: wait_ms, next_source: "calendar", retry_attempt: 0, retry_in_ms: 0)
    } else {
      let wait_ms = if runtime.next_mono_ms > now.mono_ms { runtime.next_mono_ms - now.mono_ms } else { 0 }
      views[job.name] = TimerView(state: "idle", next_wall_ms: now.wall_ms + wait_ms, next_in_ms: wait_ms, next_source: "monotonic", retry_attempt: 0, retry_in_ms: 0)
    }
  }
  views
}

proc timer_status_write(
  status_path: Path,
  pid: Int,
  jobs: List[TimerJob],
  problems: List[TimerProblem],
  states: Map[TimerState],
  runtimes: Map[TimerRuntime],
  cancelled: Set[Str],
  now: TimerClock,
  armed_wall_ms: Int,
  boot_id: Str,
  resume: Str,
  last_step: TimerStep?,
) [fs, error] -> Result[Unit, Error] {
  match status_path.parent().mkdir() {
    Ok(_) => {}
    Err(problem) => {
      guard problem.errno == 17 else {
        return Err(problem)
      }
    }
  }
  let views = timer_views(jobs, states, runtimes, cancelled, now)
  let snapshot = timer_snapshot(jobs, problems, states, views, now, armed_wall_ms, pid, boot_id, resume, last_step)?
  status_path.write_atomic(json.encode(snapshot)? + "\n")
}

proc timer_sleep_wait(
  jobs: List[TimerJob],
  runtimes: Map[TimerRuntime],
  cancelled: Set[Str],
  now: TimerClock,
) -> Int {
  var wait_ms = TIMER_POLL_MAX_MS
  for job in jobs {
    let runtime = runtimes.get(job.name) ?? timer_initial_runtime(job, timer_state_new(job.name), now)
    var candidate = TIMER_POLL_MAX_MS
    if job.name in cancelled {
      candidate = TIMER_POLL_MAX_MS
    } else if runtime.retry_at_mono_ms > 0 {
      candidate = if runtime.retry_at_mono_ms > now.mono_ms { runtime.retry_at_mono_ms - now.mono_ms } else { 0 }
    } else if runtime.pending_start or runtime.queued {
      candidate = 0
    } else if job.schedule == "calendar" {
      candidate = if runtime.next_wall_ms > now.wall_ms { runtime.next_wall_ms - now.wall_ms } else { 0 }
    } else {
      candidate = if runtime.next_mono_ms > now.mono_ms { runtime.next_mono_ms - now.mono_ms } else { 0 }
    }
    if candidate < wait_ms {
      wait_ms = candidate
    }
  }
  if wait_ms < 10 {
    wait_ms = 10
  }
  wait_ms
}

proc timers_run(config: SchedulerConfig) [fs, process, time, env, io, error] -> Result[Unit, Error] {
  config.state_dir.mkdir(parents: true)?
  config.run_dir.mkdir(parents: true)?
  let lock = fs.lock(fp"{config.run_dir}/{TIMER_LOCK_NAME}", nonblocking: true) ?? { |problem|
    return Err(error.failure(f"another laputa-timers process owns {config.run_dir}: {problem.message}"))
  }
  defer fs.unlock(lock)

  let loaded = timer_load_jobs(config.job_dir)?
  let stored = timer_load_state(fp"{config.state_dir}/{TIMER_STATE_NAME}")?
  let armed = timer_read_clock()?
  let boot_id = timer_read_boot_id()
  let store = TimerWriterStore(
    dir: fp"{config.state_dir}/{TIMER_WRITER_DIR}",
    quiesce_dir: fp"{config.state_dir}/{TIMER_QUIESCE_DIR}",
    boot_id: boot_id,
  )
  var releases: Map[TimerRelease] = {}
  for name in timer_writer_names(store)? {
    let _ = timer_writer_settle(store, name)?
  }
  var states: Map[TimerState] = {}
  var runtimes: Map[TimerRuntime] = {}
  var dirty = false
  for job in loaded.jobs {
    let before = stored.get(job.name) ?? timer_state_new(job.name)
    var state = timer_interrupted(before)
    let runtime = timer_initial_runtime(job, state, armed)
    if job.schedule == "calendar" and runtime.next_wall_ms != (state.calendar_next_wall_ms ?? 0) {
      state = timer_state_anchored(state, runtime.next_wall_ms)
      dirty = true
    }
    if state.last_outcome != before.last_outcome {
      dirty = true
    }
    states[job.name] = state
    runtimes[job.name] = runtime
  }
  if dirty {
    timer_save_state(fp"{config.state_dir}/{TIMER_STATE_NAME}", loaded.jobs, states)?
  }
  var cancelled = timer_load_cancels(fp"{config.state_dir}/{TIMER_CANCEL_DIR}")?
  var running: List[TimerRunning] = []
  var previous = armed
  var resume = "steady"
  var last_step: TimerStep? = null
  let pid = process.current_pid()?
  for problem in loaded.problems {
    timer_log(f"event=job-invalid file={problem.file} message={problem.message}")?
  }
  timer_log(f"event=start pid={pid} boot_id={boot_id} jobs={loaded.jobs.len()} invalid={loaded.problems.len()} cancelled={cancelled.len()} armed_wall_ms={armed.wall_ms}")?
  timer_status_write(fp"{config.run_dir}/{TIMER_STATUS_NAME}", pid, loaded.jobs, loaded.problems, states, runtimes, cancelled, armed, armed.wall_ms, boot_id, resume, last_step)?

  let notify = e"NOTIFY_FD" ?? ""
  if ! notify.is_empty() {
    let channel = notify.parse_int()?
    assert unix.write_fd(channel, b"r")? == 1
    unix.close_fd(channel)?
  }

  loop {
    let now = timer_read_clock()?
    let observed = timer_resume_kind(now.wall_ms - previous.wall_ms, now.mono_ms - previous.mono_ms, TIMER_STEP_TOLERANCE_MS)
    if observed != "steady" {
      resume = observed
      last_step = TimerStep(
        kind: observed,
        wall_delta_ms: now.wall_ms - previous.wall_ms,
        mono_delta_ms: now.mono_ms - previous.mono_ms,
        at_wall_ms: now.wall_ms,
      )
      timer_log(f"event=resume kind={observed} wall_delta_ms={now.wall_ms - previous.wall_ms} mono_delta_ms={now.mono_ms - previous.mono_ms}")?
      if observed == "wall-backward" {
        for job in loaded.jobs {
          if job.schedule != "calendar" or job.name in cancelled {
            continue
          }
          var runtime = runtimes.get(job.name) ?? timer_initial_runtime(job, states.get(job.name) ?? timer_state_new(job.name), now)
          let anchored = timer_calendar_next(job.hour, job.minute, now.wall_ms)
          if anchored != runtime.next_wall_ms {
            runtime.next_wall_ms = anchored
            runtimes[job.name] = runtime
            var state = states.get(job.name) ?? timer_state_new(job.name)
            state = timer_state_anchored(state, anchored)
            states[job.name] = state
            dirty = true
            timer_log(f"event=calendar-reanchor name={job.name} wall_ms={anchored}")?
          }
        }
      }
    }
    previous = now
    cancelled = timer_load_cancels(fp"{config.state_dir}/{TIMER_CANCEL_DIR}")?
    releases = timer_quiesce_reconcile(store, TIMER_RELEASE_COMMAND, running, releases, now)?

    var started_now: List[TimerRunning] = []
    var keep: List[TimerRunning] = []
    for entry in running {
      if entry.deadline_mono_ms > 0 and now.mono_ms >= entry.deadline_mono_ms {
        let job = timer_find_job(loaded.jobs, entry.name) ?? timer_job_stub(entry.name)
        entry.handle.cancel(signal: "TERM", kill_after: time.millis(TIMER_KILL_GRACE_MS))?
        var state = states.get(entry.name) ?? timer_state_new(entry.name)
        state = timer_state_finished(state, now.wall_ms, "timeout", null)
        var runtime = runtimes.get(entry.name) ?? timer_initial_runtime(job, state, now)
        runtime.running = false
        timer_log(f"event=job-timeout name={entry.name} attempt={entry.attempt} timeout_ms={job.timeout_ms}")?
        let _ = timer_writer_settle(store, entry.name)?
        if ! (entry.name in cancelled) {
          if runtime.queued {
            let attempt = timer_start(job, state, runtime, runtime.queued_wall_ms, 1, 0, now, store)?
            state = attempt.state
            runtime = attempt.runtime
            runtime.queued = false
            if let launched = attempt.started {
              runtime.running = true
              started_now += [launched]
              timer_log(f"event=job-start name={entry.name} attempt=1 queued=1 pid={launched.handle.pid}")?
            }
          } else if let delay_value = timer_retry_delay(entry.attempt, job.retries, job.retry_delay_ms) {
            runtime.retry_attempt = entry.attempt
            runtime.retry_missed = entry.missed
            runtime.retry_wall_ms = entry.occurrence_wall_ms
            runtime.retry_at_mono_ms = now.mono_ms + delay_value
          } else {
            runtime.retry_attempt = 0
            runtime.retry_at_mono_ms = 0
          }
        }
        states[entry.name] = state
        runtimes[entry.name] = runtime
        dirty = true
        continue
      }
      keep += [entry]
    }
    running = keep

    if ! running.is_empty() {
      var handles: List[ProcessHandle] = []
      for entry in running {
        handles += [entry.handle]
      }
      let finished = process.wait_timeout(handles, 0ms)?
      if let done = finished {
        let entry = running[done.index]
        let job = timer_find_job(loaded.jobs, entry.name) ?? timer_job_stub(entry.name)
        let signaled = ! done.status.exited()
        var code: Int? = null
        if ! signaled {
          match done.status.exit_code() {
            Ok(value) => { code = value }
            Err(_) => {}
          }
        }
        let outcome = timer_outcome(code ?? 0, signaled, false)
        var state = states.get(entry.name) ?? timer_state_new(entry.name)
        state = timer_state_finished(state, now.wall_ms, outcome, code)
        var runtime = runtimes.get(entry.name) ?? timer_initial_runtime(job, state, now)
        runtime.running = false
        timer_log(f"event=job-finish name={entry.name} attempt={entry.attempt} outcome={outcome} exit={code ?? -1}")?
        let _ = timer_writer_settle(store, entry.name)?
        if ! (entry.name in cancelled) {
          if runtime.queued {
            let attempt = timer_start(job, state, runtime, runtime.queued_wall_ms, 1, 0, now, store)?
            state = attempt.state
            runtime = attempt.runtime
            runtime.queued = false
            if let launched = attempt.started {
              runtime.running = true
              started_now += [launched]
              timer_log(f"event=job-start name={entry.name} attempt=1 queued=1 pid={launched.handle.pid}")?
            }
          } else if outcome != "ok" and timer_retry_delay(entry.attempt, job.retries, job.retry_delay_ms) != null {
            runtime.retry_attempt = entry.attempt
            runtime.retry_missed = entry.missed
            runtime.retry_wall_ms = entry.occurrence_wall_ms
            runtime.retry_at_mono_ms = now.mono_ms + (timer_retry_delay(entry.attempt, job.retries, job.retry_delay_ms) ?? 0)
          } else {
            runtime.retry_attempt = 0
            runtime.retry_at_mono_ms = 0
          }
        }
        states[entry.name] = state
        runtimes[entry.name] = runtime
        dirty = true
        var kept: List[TimerRunning] = []
        var position = 0
        for item in running {
          if position != done.index {
            kept += [item]
          }
          position += 1
        }
        running = kept
      }
    }
    running += started_now

    var due_starts: List[TimerRunning] = []
    for job in loaded.jobs {
      var state = states.get(job.name) ?? timer_state_new(job.name)
      var runtime = runtimes.get(job.name) ?? timer_initial_runtime(job, state, now)
      if job.name in cancelled {
        fp"{config.state_dir}/{TIMER_TRIGGER_DIR}/{job.name}".remove(missing_ok: true)?
        var changed = false
        if timer_is_running(running, job.name) {
          runtime.running = false
          var kept: List[TimerRunning] = []
          for entry in running {
            if entry.name == job.name {
              entry.handle.cancel(signal: "TERM", kill_after: time.millis(TIMER_KILL_GRACE_MS))?
              state = timer_state_finished(state, now.wall_ms, "cancelled", null)
              state = timer_state_counted(state, 0, 0, 0, 0, 1)
              timer_log(f"event=job-cancel name={job.name} attempt={entry.attempt}")?
              let _ = timer_writer_settle(store, job.name)?
              changed = true
            } else {
              kept += [entry]
            }
          }
          running = kept
        }
        if runtime.queued {
          state = timer_state_counted(state, 0, 0, 0, 0, 1)
          runtime.queued = false
          runtime.queued_wall_ms = 0
          changed = true
          timer_log(f"event=job-cancel name={job.name} queued=1")?
        }
        if runtime.retry_at_mono_ms > 0 {
          runtime.retry_at_mono_ms = 0
          runtime.retry_attempt = 0
          runtime.retry_missed = 0
          runtime.retry_wall_ms = 0
          changed = true
        }
        if runtime.pending_start {
          runtime.pending_start = false
          runtime.pending_missed = 0
          changed = true
        }
        states[job.name] = state
        runtimes[job.name] = runtime
        if changed {
          dirty = true
        }
        continue
      }
      let trigger = fp"{config.state_dir}/{TIMER_TRIGGER_DIR}/{job.name}"
      if trigger.exists()? and ! runtime.running and ! runtime.queued and ! runtime.pending_start and runtime.retry_at_mono_ms == 0 {
        trigger.remove(missing_ok: true)?
        fs.fsync(trigger.parent())
        runtime.pending_start = true
        runtime.pending_missed = 0
        timer_log(f"event=job-run-now name={job.name}")?
      }
      if runtime.retry_at_mono_ms > 0 {
        if now.mono_ms < runtime.retry_at_mono_ms {
          runtimes[job.name] = runtime
          continue
        }
        let attempt = timer_start(job, state, runtime, runtime.retry_wall_ms, runtime.retry_attempt + 1, runtime.retry_missed, now, store)?
        state = attempt.state
        runtime = attempt.runtime
        if let launched = attempt.started {
          runtime.running = true
          runtime.retry_at_mono_ms = 0
          runtime.retry_attempt = 0
          runtime.retry_missed = 0
          runtime.retry_wall_ms = 0
          due_starts += [launched]
          timer_log(f"event=job-retry name={job.name} attempt={launched.attempt} pid={launched.handle.pid}")?
        }
        states[job.name] = state
        runtimes[job.name] = runtime
        dirty = true
        continue
      }
      if runtime.pending_start {
        state = timer_state_counted(state, runtime.pending_missed, 0, 0, 0, 0)
        let attempt = timer_start(job, state, runtime, now.wall_ms, 1, runtime.pending_missed, now, store)?
        state = attempt.state
        runtime = attempt.runtime
        runtime.pending_start = false
        runtime.pending_missed = 0
        if job.schedule == "interval" {
          runtime.next_mono_ms = now.mono_ms + job.every_ms
        }
        states[job.name] = state
        runtimes[job.name] = runtime
        dirty = true
        if let launched = attempt.started {
          runtime.running = true
          due_starts += [launched]
          timer_log(f"event=job-start name={job.name} attempt=1 missed={launched.missed} scheduled_wall_ms={launched.occurrence_wall_ms} pid={launched.handle.pid}")?
        }
        continue
      }
      if runtime.queued {
        runtimes[job.name] = runtime
        continue
      }
      let due = timer_due(job, runtime, now)
      let scheduled_wall = if job.schedule == "calendar" {
        runtime.next_wall_ms
      } else {
        now.wall_ms - (if now.mono_ms > runtime.next_mono_ms { now.mono_ms - runtime.next_mono_ms } else { 0 })
      }
      if due.kind == "wait" {
        runtime.next_mono_ms = if job.schedule == "calendar" { 0 } else { due.next_mono_ms }
        runtime.next_wall_ms = if job.schedule == "calendar" { due.next_wall_ms } else { 0 }
        if job.schedule == "calendar" and state.calendar_next_wall_ms != due.next_wall_ms {
          state = timer_state_anchored(state, due.next_wall_ms)
          dirty = true
        }
        states[job.name] = state
        runtimes[job.name] = runtime
        continue
      }
      if due.kind == "skipped-missed" {
        state = timer_state_counted(state, 0, due.missed, 0, 0, 0)
        runtime.next_mono_ms = if job.schedule == "calendar" { 0 } else { due.next_mono_ms }
        runtime.next_wall_ms = if job.schedule == "calendar" { due.next_wall_ms } else { 0 }
        if job.schedule == "calendar" {
          state = timer_state_anchored(state, due.next_wall_ms)
        }
        states[job.name] = state
        runtimes[job.name] = runtime
        dirty = true
        timer_log(f"event=job-skip name={job.name} reason=missed count={due.missed}")?
        continue
      }
      let action = timer_overlap_action(job.overlap, timer_is_running(running, job.name), runtime.queued)
      if action == "queue" {
        state = timer_state_counted(state, due.missed, 0, 0, 1, 0)
        runtime.next_mono_ms = if job.schedule == "calendar" { 0 } else { due.next_mono_ms }
        runtime.next_wall_ms = if job.schedule == "calendar" { due.next_wall_ms } else { 0 }
        runtime.queued = true
        runtime.queued_wall_ms = scheduled_wall
        if job.schedule == "calendar" {
          state = timer_state_anchored(state, due.next_wall_ms)
        }
        states[job.name] = state
        runtimes[job.name] = runtime
        dirty = true
        timer_log(f"event=job-queue name={job.name} missed={due.missed} scheduled_wall_ms={scheduled_wall}")?
        continue
      }
      if action == "skip" {
        state = timer_state_counted(state, 0, 0, 1 + due.missed, 0, 0)
        runtime.next_mono_ms = if job.schedule == "calendar" { 0 } else { due.next_mono_ms }
        runtime.next_wall_ms = if job.schedule == "calendar" { due.next_wall_ms } else { 0 }
        if job.schedule == "calendar" {
          state = timer_state_anchored(state, due.next_wall_ms)
        }
        states[job.name] = state
        runtimes[job.name] = runtime
        dirty = true
        timer_log(f"event=job-skip name={job.name} reason=overlap count={1 + due.missed}")?
        continue
      }
      state = timer_state_counted(state, due.missed, 0, 0, 0, 0)
      let attempt = timer_start(job, state, runtime, scheduled_wall, 1, due.missed, now, store)?
      state = attempt.state
      runtime = attempt.runtime
      runtime.next_mono_ms = if job.schedule == "calendar" { 0 } else { due.next_mono_ms }
      runtime.next_wall_ms = if job.schedule == "calendar" { due.next_wall_ms } else { 0 }
      if job.schedule == "calendar" {
        state = timer_state_anchored(state, due.next_wall_ms)
      }
      states[job.name] = state
      runtimes[job.name] = runtime
      dirty = true
      if let launched = attempt.started {
        runtime.running = true
        due_starts += [launched]
        timer_log(f"event=job-start name={job.name} attempt=1 missed={due.missed} scheduled_wall_ms={scheduled_wall} pid={launched.handle.pid}")?
      }
    }
    running += due_starts

    if dirty {
      timer_save_state(fp"{config.state_dir}/{TIMER_STATE_NAME}", loaded.jobs, states)?
      dirty = false
    }
    timer_status_write(fp"{config.run_dir}/{TIMER_STATUS_NAME}", pid, loaded.jobs, loaded.problems, states, runtimes, cancelled, now, armed.wall_ms, boot_id, resume, last_step)?
    let wait_ms = timer_sleep_wait(loaded.jobs, runtimes, cancelled, now)
    time.sleep(time.millis(wait_ms))?
  }
}

proc timers_run_now(config: SchedulerConfig, name: Str) [fs, io, error] -> Result[Unit, Error] {
  let loaded = timer_load_jobs(config.job_dir)?
  guard timer_find_job(loaded.jobs, name) != null else {
    return Err(error.failure(f"unknown timer job {name}"))
  }
  let dir = fp"{config.state_dir}/{TIMER_TRIGGER_DIR}"
  dir.mkdir(parents: true)?
  atomically replace fp"{dir}/{name}" as next {
    next.write("run-now\n", mode: 0o644)
    fs.fsync(next)
  }
  fs.fsync(dir)
  print f"laputa-timers run-now {name}"
}

proc timers_cancel(config: SchedulerConfig, name: Str, active: Bool) [fs, io, error] -> Result[Unit, Error] {
  let loaded = timer_load_jobs(config.job_dir)?
  guard timer_find_job(loaded.jobs, name) != null else {
    return Err(error.failure(f"unknown timer job {name}"))
  }
  timer_write_cancel(fp"{config.state_dir}/{TIMER_CANCEL_DIR}", name, active)?
  let verb = if active { "cancel" } else { "resume" }
  print f"laputa-timers {verb} {name}"
}

## Run, inspect, cancel, or resume timer jobs.
export proc timers_main(...argv: List[Str]) [fs, process, time, env, io, error] -> Result[Unit, Error] {
  let parsed = match timer_options(argv) {
    Ok(value) => value
    Err(problem) => {
      eprint f"laputa-timers: {problem}"
      eprint $TIMER_USAGE
      exit 2
    }
  }
  if parsed.help {
    print $TIMER_USAGE
    return
  }
  let config = SchedulerConfig(job_dir: fp"{parsed.job_dir}", state_dir: fp"{parsed.state_dir}", run_dir: fp"{parsed.run_dir}")
  match parsed.action {
    "run" => timers_run(config)
    "status" => timers_status(config, parsed.json)
    "cancel" => timers_cancel(config, parsed.name, true)
    "resume" => timers_cancel(config, parsed.name, false)
    "run-now" => timers_run_now(config, parsed.name)
    else => Err(error.failure(f"unknown timer action {parsed.action}"))
  }
}

## Entry point when this module runs as a script. The packaged wrapper adds the
## termination hook that cleans up job process groups.
export proc main(...argv: List[Str]) [fs, process, time, env, io, error] -> Result[Unit, Error] {
  timers_main(@argv)
}
