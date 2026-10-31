use xinfra.host
use xinfra.outcome
use xinfra.plan
use xinfra.redact
use xinfra.report

proc sample_rows() -> List[report.ResultRow] {
  [
    report.row("run-1", "web-1", "motd", "apply", outcome.Changed, true, "", 7),
    report.row("run-1", "web-1", "nginx", "apply", outcome.Unchanged, true, "", 1),
  ]
}

test test_golden_json_schema { |ctx|
  let built = report.build("run-1", sample_rows(), 0)
  let rendered = report.render(built, report.Json, redact.empty())?
  test.eq(
    rendered,
    """{"kind":"report","results":[{"cause":"","duration_ms":7,"host":"web-1","kind":"result","outcome":"changed","phase":"apply","resource":"motd","run_id":"run-1","schema_version":1,"verified":true},{"cause":"","duration_ms":1,"host":"web-1","kind":"result","outcome":"unchanged","phase":"apply","resource":"nginx","run_id":"run-1","schema_version":1,"verified":true}],"run_id":"run-1","schema_version":1,"summary":{"blocked":0,"changed":1,"exit":0,"failed":0,"hosts":["web-1"],"kind":"summary","partial":0,"run_id":"run-1","schema_version":1,"skipped":0,"unchanged":1,"unknown":0}}
""",
  )?
}

test test_golden_jsonl_schema { |ctx|
  let built = report.build("run-1", sample_rows(), 0)
  let rendered = report.render(built, report.Jsonl, redact.empty())?
  test.eq(
    rendered,
    """{"cause":"","duration_ms":7,"host":"web-1","kind":"result","outcome":"changed","phase":"apply","resource":"motd","run_id":"run-1","schema_version":1,"verified":true}
{"cause":"","duration_ms":1,"host":"web-1","kind":"result","outcome":"unchanged","phase":"apply","resource":"nginx","run_id":"run-1","schema_version":1,"verified":true}
{"blocked":0,"changed":1,"exit":0,"failed":0,"hosts":["web-1"],"kind":"summary","partial":0,"run_id":"run-1","schema_version":1,"skipped":0,"unchanged":1,"unknown":0}
""",
  )?
}

test test_summary_counts_and_exit_rules { |ctx|
  let values = [outcome.Changed, outcome.Unchanged, outcome.Changed, outcome.Skipped]
  let totals = outcome.counts(values)
  test.eq(totals.changed, 2)?
  test.eq(totals.unchanged, 1)?
  test.eq(totals.skipped, 1)?
  test.eq(outcome.apply_exit(totals), 0)?
  test.eq(outcome.check_exit(totals), 1)?

  let failed = outcome.counts([outcome.Failed, outcome.Changed])
  test.eq(outcome.apply_exit(failed), 1)?
  test.eq(outcome.check_exit(failed), 2)?
  test.eq(outcome.doctor_exit(failed), 1)?
  test.eq(outcome.interrupted_exit(), 130)?

  let unknown = outcome.counts([outcome.Unknown])
  test.eq(outcome.apply_exit(unknown), 1)?
  test.eq(outcome.check_exit(unknown), 2)?
  test.eq(outcome.check_exit(outcome.counts([outcome.Unchanged])), 0)?
  test.eq(outcome.of_status(host.Partial), outcome.Partial)?
  test.eq(outcome.of_prediction(plan.Undetermined), outcome.Unknown)?
}

test test_control_sequences_are_sanitized { |ctx|
  let cause = "bad\x1b[31mred\x07end"
  let built = report.build(
    "run-1",
    [report.row("run-1", "web-1", "motd", "apply", outcome.Failed, false, cause, 3)],
    1,
  )
  let human = report.render(built, report.Human, redact.empty())?
  test.ok("bad?[31mred?end" in human)?
  test.ok("\x1b" not in human)?
  let structured = report.render(built, report.Json, redact.empty())?
  test.ok("bad?[31mred?end" in structured)?
  test.ok("\x1b" not in structured)?
}

test test_overlong_utf8_cause_truncates_on_a_boundary { |ctx|
  let pieces: List[Str] = collect {
    for index in range(3000) {
      let _ = index
      yield "€"
    }
  }
  let cause = pieces.join("")
  let built = report.build(
    "run-1",
    [report.row("run-1", "web-1", "motd", "apply", outcome.Failed, false, cause, 3)],
    1,
  )
  let human = report.render(built, report.Human, redact.empty())?
  let structured = report.render(built, report.Json, redact.empty())?
  test.ok("truncated" in human)?
  test.ok("truncated" in structured)?
}

test test_exact_secrets_are_redacted_everywhere { |ctx|
  let redactor = redact.with_secret(redact.empty(), "canary-value")
  let built = report.build(
    "run-1",
    [report.row("run-1", "web-1", "token", "apply", outcome.Failed, false, "wrote canary-value", 2)],
    1,
  )
  let human = report.render(built, report.Human, redactor)?
  test.ok("[redacted]" in human)?
  test.ok("canary-value" not in human)?
  let structured = report.render(built, report.Json, redactor)?
  test.ok("[redacted]" in structured)?
  test.ok("canary-value" not in structured)?
  let lines = report.render(built, report.Jsonl, redactor)?
  test.ok("[redacted]" in lines)?
  test.ok("canary-value" not in lines)?
}

test test_redaction_prefers_the_longest_secret { |ctx|
  var redactor = redact.empty()
  redactor = redact.with_secret(redactor, "canary")
  redactor = redact.with_secret(redactor, "canary-value")
  test.eq(redact.redact("canary-value", redactor), "[redacted]")?
  test.eq(redact.redact("canary and canary-value", redactor), "[redacted] and [redacted]")?
}
