##! Pure scheduling decisions, validated with an injected clock.
use system.timers

const BASE = 1767225600000
const DAY = 86400000
const HOUR = 3600000
const MINUTE = 60000

pure at(mono_ms: Int, wall_ms: Int) -> timers.TimerClock {
  {mono_ms: mono_ms, wall_ms: wall_ms}
}

pure interval_job(every_ms: Int, overlap: Str, missed: Str, retries: Int, retry_delay_ms: Int) -> timers.TimerJob {
  {
    name: "interval",
    file: "interval.json",
    schedule: "interval",
    every_ms: every_ms,
    hour: 0,
    minute: 0,
    argv: ["/usr/bin/true"],
    timeout_ms: 0,
    overlap: overlap,
    missed: missed,
    retries: retries,
    retry_delay_ms: retry_delay_ms,
  }
}

pure calendar_job(hour: Int, minute: Int, overlap: Str, missed: Str) -> timers.TimerJob {
  {
    name: "calendar",
    file: "calendar.json",
    schedule: "calendar",
    every_ms: 0,
    hour: hour,
    minute: minute,
    argv: ["/usr/bin/true"],
    timeout_ms: 0,
    overlap: overlap,
    missed: missed,
    retries: 0,
    retry_delay_ms: 0,
  }
}

pure raw_job(fields: Record) -> Result[Any, Error] {
  let base = {
    format: "laputa-timer-job-1",
    name: "probe",
    schedule: {kind: "interval", every_ms: 5000},
    command: ["/usr/bin/true"],
    timeout_ms: 0,
    overlap: "skip",
    missed: "coalesce",
    retries: {max: 0, delay_ms: 0},
  }
  var merged: Map[Any] = {}
  for key in base.keys() {
    merged[key] = base[key]
  }
  for key in fields.keys() {
    merged[key] = fields[key]
  }
  json.decode(json.encode(merged)?)?
}

test test_interval_waits_before_its_first_deadline [error] {
  let due = timers.timer_interval_due(5000, 6000, 1000, "coalesce")
  assert due.kind == "wait"
  assert due.missed == 0
  assert due.next_mono_ms == 6000
  assert due.next_in_ms == 5000
}

test test_interval_starts_exactly_on_its_deadline [error] {
  let due = timers.timer_interval_due(5000, 6000, 6000, "coalesce")
  assert due.kind == "start"
  assert due.missed == 0
  assert due.next_mono_ms == 11000
}

test test_interval_coalesces_every_missed_occurrence_into_one_start [error] {
  let due = timers.timer_interval_due(5000, 6000, 23000, "coalesce")
  assert due.kind == "coalesced-start"
  assert due.missed == 3
  assert due.next_mono_ms == 28000
  assert due.next_in_ms == 5000
}

test test_interval_skip_discards_a_missed_grid_without_a_burst [error] {
  let due = timers.timer_interval_due(5000, 6000, 23000, "skip")
  assert due.kind == "skipped-missed"
  assert due.missed == 4
  assert due.next_mono_ms == 28000
}

test test_interval_skip_still_runs_an_on_time_occurrence [error] {
  let due = timers.timer_interval_due(5000, 6000, 6000, "skip")
  assert due.kind == "start"
  assert due.missed == 0
}

test test_calendar_next_uses_utc_and_rolls_to_tomorrow [error] {
  assert timers.timer_calendar_next(3, 17, BASE + HOUR) == BASE + 3 * HOUR + 17 * MINUTE
  assert timers.timer_calendar_next(3, 17, BASE + 3 * HOUR + 17 * MINUTE) == BASE + DAY + 3 * HOUR + 17 * MINUTE
  assert timers.timer_calendar_next(0, 0, BASE) == BASE + DAY
}

test test_calendar_occurrences_count_inclusive_anchors [error] {
  assert timers.timer_calendar_occurrences(BASE, BASE - 1) == 0
  assert timers.timer_calendar_occurrences(BASE, BASE) == 1
  assert timers.timer_calendar_occurrences(BASE, BASE + 2 * DAY + HOUR) == 3
}

test test_calendar_starts_on_its_occurrence_and_advances_one_day [error] {
  let anchor = BASE + 3 * HOUR + 17 * MINUTE
  let due = timers.timer_calendar_due(3, 17, anchor, anchor, "coalesce")
  assert due.kind == "start"
  assert due.missed == 0
  assert due.next_wall_ms == anchor + DAY
}

test test_calendar_coalesces_downtime_days_into_one_start [error] {
  let due = timers.timer_calendar_due(3, 17, BASE, BASE + 2 * DAY + HOUR, "coalesce")
  assert due.kind == "coalesced-start"
  assert due.missed == 2
  assert due.next_wall_ms == BASE + 2 * DAY + 3 * HOUR + 17 * MINUTE
}

test test_calendar_skip_discards_a_missed_day [error] {
  let due = timers.timer_calendar_due(3, 17, BASE, BASE + 2 * DAY + HOUR, "skip")
  assert due.kind == "skipped-missed"
  assert due.missed == 3
  assert due.next_wall_ms == BASE + 2 * DAY + 3 * HOUR + 17 * MINUTE
}

test test_calendar_forward_wall_step_runs_once_then_waits [error] {
  let anchor = BASE + 3 * HOUR + 17 * MINUTE
  let stepped = anchor + 5 * HOUR
  let first = timers.timer_calendar_due(3, 17, anchor, stepped, "coalesce")
  assert first.kind == "start"
  assert first.missed == 0
  let second = timers.timer_calendar_due(3, 17, first.next_wall_ms, stepped, "coalesce")
  assert second.kind == "wait"
  assert second.next_wall_ms == anchor + DAY
}

test test_calendar_backward_wall_step_reanchors_the_next_occurrence [error] {
  let anchor = BASE + 10 * DAY
  let due = timers.timer_calendar_due(3, 17, anchor, BASE, "coalesce")
  assert due.kind == "wait"
  assert due.next_wall_ms == BASE + 3 * HOUR + 17 * MINUTE
  assert due.next_in_ms == 3 * HOUR + 17 * MINUTE
}

test test_interval_startup_waits_after_a_fresh_install [error] {
  let due = timers.timer_interval_start(5000, null, at(1000, BASE), "coalesce")
  assert due.kind == "wait"
  assert due.next_mono_ms == 6000
  assert due.next_in_ms == 5000
}

test test_interval_startup_keeps_the_remaining_budget_from_wall_downtime [error] {
  let due = timers.timer_interval_start(10000, BASE - 4000, at(1000, BASE), "coalesce")
  assert due.kind == "wait"
  assert due.next_mono_ms == 7000
  assert due.next_in_ms == 6000
}

test test_interval_startup_coalesces_reboot_downtime_into_one_catch_up [error] {
  let due = timers.timer_interval_start(10000, BASE - 34000, at(1000, BASE), "coalesce")
  assert due.kind == "coalesced-start"
  assert due.missed == 2
  assert due.next_mono_ms == 1000
  assert due.next_in_ms == 0
}

test test_interval_startup_skip_discards_the_same_downtime [error] {
  let due = timers.timer_interval_start(10000, BASE - 34000, at(1000, BASE), "skip")
  assert due.kind == "skipped-missed"
  assert due.missed == 3
  assert due.next_mono_ms == 11000
}

test test_interval_startup_never_catches_up_on_a_backward_wall [error] {
  let due = timers.timer_interval_start(10000, BASE + DAY, at(1000, BASE), "coalesce")
  assert due.kind == "wait"
  assert due.next_mono_ms == 11000
}

test test_calendar_startup_uses_the_persisted_anchor [error] {
  let due = timers.timer_calendar_start(3, 17, BASE - 2 * DAY, at(1000, BASE), "coalesce")
  assert due.kind == "coalesced-start"
  assert due.missed == 2
  assert due.next_wall_ms == BASE + 3 * HOUR + 17 * MINUTE
}

test test_calendar_startup_without_state_waits_for_the_next_occurrence [error] {
  let due = timers.timer_calendar_start(3, 17, null, at(1000, BASE + HOUR), "coalesce")
  assert due.kind == "wait"
  assert due.next_wall_ms == BASE + 3 * HOUR + 17 * MINUTE
}

test test_startup_due_selects_the_schedule_kind [error] {
  let interval = timers.timer_startup_due(interval_job(5000, "skip", "coalesce", 0, 0), timers.timer_state_new("interval"), at(0, BASE))
  assert interval.kind == "wait"
  assert interval.next_mono_ms == 5000
  let calendar = timers.timer_startup_due(calendar_job(3, 17, "skip", "coalesce"), timers.timer_state_new("calendar"), at(0, BASE))
  assert calendar.kind == "wait"
  assert calendar.next_wall_ms == BASE + 3 * HOUR + 17 * MINUTE
}

test test_overlap_policy_is_per_job [error] {
  assert timers.timer_overlap_action("skip", false, false) == "start"
  assert timers.timer_overlap_action("skip", true, false) == "skip"
  assert timers.timer_overlap_action("queue", true, false) == "queue"
  assert timers.timer_overlap_action("queue", true, true) == "skip"
}

test test_cancellation_terminates_a_run_and_drops_a_queue [error] {
  assert timers.timer_cancel_action(false, true, true) == "active"
  assert timers.timer_cancel_action(true, true, false) == "terminate"
  assert timers.timer_cancel_action(true, false, true) == "drop"
  assert timers.timer_cancel_action(true, false, false) == "hold"
}

test test_retries_are_bounded_by_the_definition [error] {
  assert timers.timer_retry_delay(1, 2, 500) == 500
  assert timers.timer_retry_delay(2, 2, 500) == 500
  assert timers.timer_retry_delay(3, 2, 500) == null
  assert timers.timer_retry_delay(1, 0, 500) == null
}

test test_resume_classification_separates_gaps_from_wall_steps [error] {
  assert timers.timer_resume_kind(0, 0, 2000) == "steady"
  assert timers.timer_resume_kind(1000, 500, 2000) == "steady"
  assert timers.timer_resume_kind(5000, 5000, 2000) == "gap"
  assert timers.timer_resume_kind(10000, 0, 2000) == "wall-forward"
  assert timers.timer_resume_kind(-10000, 0, 2000) == "wall-backward"
}

test test_run_outcomes_are_distinct [error] {
  assert timers.timer_outcome(0, false, false) == "ok"
  assert timers.timer_outcome(7, false, false) == "failed"
  assert timers.timer_outcome(0, true, false) == "signaled"
  assert timers.timer_outcome(0, false, true) == "timeout"
}

test test_state_transitions_count_runs_and_failures [error] {
  let fresh = timers.timer_state_new("probe")
  assert fresh.runs == 0 and fresh.last_outcome == "never"
  let started = timers.timer_state_started(fresh, BASE)
  assert started.runs == 1
  assert started.last_start_wall_ms == BASE
  assert started.last_outcome == "running"
  let failed = timers.timer_state_finished(started, BASE + 100, "failed", 9)
  assert failed.failures == 1
  assert failed.last_finish_wall_ms == BASE + 100
  assert failed.last_exit_code == 9
  let cancelled = timers.timer_state_finished(started, BASE + 100, "cancelled", null)
  assert cancelled.failures == 0
  let counted = timers.timer_state_counted(started, 2, 1, 3, 1, 0)
  assert counted.coalesced == 2 and counted.skipped_missed == 1 and counted.skipped_overlap == 3 and counted.queued == 1
}

test test_a_run_left_running_by_the_scheduler_becomes_interrupted [error] {
  let started = timers.timer_state_started(timers.timer_state_new("probe"), BASE)
  let normalized = timers.timer_interrupted(started)
  assert normalized.last_outcome == "interrupted"
  assert normalized.last_finish_wall_ms == null
  assert normalized.runs == 1
}

test test_valid_interval_definition_decodes [error] {
  let decoded = timers.timer_job_from_json("probe", raw_job({})?)?
  assert decoded.name == "probe"
  assert decoded.schedule == "interval"
  assert decoded.every_ms == 5000
  assert decoded.overlap == "skip"
  assert decoded.missed == "coalesce"
  assert decoded.retries == 0
}

test test_valid_calendar_definition_decodes [error] {
  let value = raw_job({schedule: {kind: "calendar", hour: 23, minute: 59}})?
  let decoded = timers.timer_job_from_json("probe", value)?
  assert decoded.schedule == "calendar"
  assert decoded.hour == 23
  assert decoded.minute == 59
}

test test_definition_defaults_are_applied [error] {
  let value = raw_job({timeout_ms: 1000, retries: {max: 2, delay_ms: 250}})?
  let decoded = timers.timer_job_from_json("probe", value)?
  assert decoded.timeout_ms == 1000
  assert decoded.retries == 2
  assert decoded.retry_delay_ms == 250
  let defaults = raw_job({})?
  let plain = timers.timer_job_from_json("probe", defaults)?
  assert plain.timeout_ms == 0
}

test test_definition_rejects_mismatched_file_name [error] {
  let decoded = timers.timer_job_from_json("other", raw_job({})?)
  assert decoded is Err(_)
}

test test_definition_rejects_unknown_keys [error] {
  let decoded = timers.timer_job_from_json("probe", raw_job({overlapp: "skip"})?)
  assert decoded is Err(_)
}

test test_definition_rejects_an_explicit_overlap_only [error] {
  let value = raw_job({})?
  let without = json.remove(value, ["overlap"])?
  let decoded = timers.timer_job_from_json("probe", without)
  assert decoded is Err(_)
}

test test_definition_rejects_out_of_range_schedules [error] {
  assert timers.timer_job_from_json("probe", raw_job({schedule: {kind: "interval", every_ms: 999}})?) is Err(_)
  assert timers.timer_job_from_json("probe", raw_job({schedule: {kind: "interval", every_ms: 31536000001}})?) is Err(_)
  assert timers.timer_job_from_json("probe", raw_job({schedule: {kind: "calendar", hour: 24, minute: 0}})?) is Err(_)
  assert timers.timer_job_from_json("probe", raw_job({schedule: {kind: "weekly"}})?) is Err(_)
}

test test_definition_rejects_an_empty_or_relative_command [error] {
  assert timers.timer_job_from_json("probe", raw_job({command: []})?) is Err(_)
  assert timers.timer_job_from_json("probe", raw_job({command: ["true"]})?) is Err(_)
}

test test_definition_rejects_unbounded_retries_and_bad_overlap [error] {
  assert timers.timer_job_from_json("probe", raw_job({retries: {max: 11, delay_ms: 0}})?) is Err(_)
  assert timers.timer_job_from_json("probe", raw_job({overlap: "restart"})?) is Err(_)
  assert timers.timer_job_from_json("probe", raw_job({missed: "burst"})?) is Err(_)
}

test test_writer_verdict_proves_a_stopped_group_only_by_identity [error] {
  assert timers.timer_writer_verdict("boot-a", "boot-a", false, 0, 700) == "gone"
  assert timers.timer_writer_verdict("boot-a", "boot-a", true, 700, 700) == "alive"
  assert timers.timer_writer_verdict("boot-a", "boot-a", true, 0, 700) == "alive"
  assert timers.timer_writer_verdict("boot-a", "boot-a", true, 900, 700) == "gone"
  assert timers.timer_writer_verdict("boot-a", "boot-b", true, 700, 700) == "gone"
  assert timers.timer_writer_verdict("boot-a", "", true, 700, 700) == "alive"
  assert timers.timer_writer_verdict("", "boot-b", true, 700, 700) == "alive"
}

test test_writer_record_refuses_foreign_or_malformed_input [error] {
  let good = {format: timers.TIMER_WRITER_FORMAT, name: "backup", attempt: 2, boot_id: "b", pid: 4242, start_time_ms: 9, started_wall_ms: 5}
  let record = timers.timer_writer_from_json(good)?
  assert record.name == "backup" and record.pid == 4242 and record.attempt == 2
  assert timers.timer_writer_from_json({format: "other", name: "backup", pid: 4242}) is Err(_)
  assert timers.timer_writer_from_json({format: timers.TIMER_WRITER_FORMAT, name: "../x", pid: 4242}) is Err(_)
  assert timers.timer_writer_from_json({format: timers.TIMER_WRITER_FORMAT, name: "backup", pid: 1}) is Err(_)
  assert timers.timer_writer_from_json({format: timers.TIMER_WRITER_FORMAT, name: "backup", pid: "x"}) is Err(_)
}

proc writer_group_live(pid: Int) [process, error] -> Result[Bool, Error] {
  for entry in process.list()? {
    if (entry.pgrp ?? 0) == pid and ! entry.status.starts_with("Z") {
      return Ok(true)
    }
  }
  Ok(false)
}

proc writer_spawn(root: Path, script: Str) [fs, process, error] -> Result[ProcessHandle, Error] {
  let handle = spawn process.command_argv("/bin/sh", ["sh", "-c", script], cwd: root, stdin: p"/dev/null")?
  Ok(handle)
}

proc writer_record(store: timers.TimerWriterStore, handle: ProcessHandle, name: Str) [fs, process, error] -> Result[timers.TimerWriter, Error] {
  let record = timers.TimerWriter(
    name: name,
    attempt: 1,
    boot_id: store.boot_id,
    pid: handle.pid,
    start_time_ms: timers.timer_process_start_ms(handle.pid)?,
    started_wall_ms: 0,
  )
  timers.timer_writer_save(store, record)?
  Ok(record)
}

test test_restarted_supervisor_proves_an_orphaned_writer_group_stopped [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let root = test.temp_dir(ctx, name: "writer-orphan")?
  let store = timers.TimerWriterStore(dir: fp"{root}/runs", boot_id: "boot-1")
  let handle = writer_spawn(root, "sleep 300 & echo $! > child.pid; wait")?
  let record = writer_record(store, handle, "backup")?
  var waited = 0
  while ! fp"{root}/child.pid".exists()? and waited < 5000 {
    time.sleep(50ms)?
    waited += 50
  }
  assert fp"{root}/child.pid".exists()?
  assert timers.timer_writer_names(store)? == ["backup"]

  # The job leader dies first and leaves the snapshot writer behind in its group.
  process.kill(handle.pid, "KILL")?
  let _ = process.wait_timeout([handle], 5s)?
  assert writer_group_live(record.pid)?

  # A restarted supervisor has only the record; it must stop the orphan before it reports success.
  let restarted = timers.TimerWriterStore(dir: store.dir, boot_id: "boot-1")
  assert timers.timer_writer_settle(restarted, "backup")? == "settled"
  assert ! writer_group_live(record.pid)?
  assert timers.timer_writer_names(restarted)? == []
  assert timers.timer_writer_settle(restarted, "backup")? == "none"
}

test test_recycled_or_foreign_boot_records_never_signal_a_live_group [fs, process, time, io, error] { |ctx|
  test.timeout(ctx, 60s)
  let root = test.temp_dir(ctx, name: "writer-recycled")?
  let store = timers.TimerWriterStore(dir: fp"{root}/runs", boot_id: "boot-1")
  let bystander = writer_spawn(root, "sleep 300")?
  let live = writer_record(store, bystander, "backup")?
  let recycled = timers.TimerWriter(
    name: live.name,
    attempt: 1,
    boot_id: "boot-1",
    pid: live.pid,
    start_time_ms: live.start_time_ms + 1000,
    started_wall_ms: 0,
  )
  timers.timer_writer_save(store, recycled)?
  assert timers.timer_writer_settle(store, "backup")? == "settled"
  assert writer_group_live(live.pid)?

  let other_boot = timers.TimerWriter(
    name: live.name,
    attempt: 1,
    boot_id: "boot-0",
    pid: live.pid,
    start_time_ms: live.start_time_ms,
    started_wall_ms: 0,
  )
  timers.timer_writer_save(store, other_boot)?
  assert timers.timer_writer_settle(store, "backup")? == "settled"
  assert writer_group_live(live.pid)?

  timers.timer_writer_save(store, live)?
  assert timers.timer_writer_settle(store, "backup")? == "settled"
  let _ = process.wait_timeout([bystander], 5s)?
  assert ! writer_group_live(live.pid)?
}
