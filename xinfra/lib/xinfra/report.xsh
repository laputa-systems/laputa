##! Schema-version-1 report rows, summaries, and human/JSON rendering.

use xinfra.outcome
use xinfra.redact

const SCHEMA_VERSION = 1
const CONTROL = rx"[\x00-\x1f\x7f]|\xc2[\x80-\x9f]"
const MAX_FIELD_BYTES = 4096

## The output style selected on the command line.
export enum Style: Str {
  Human = "human",
  Json = "json",
  Jsonl = "jsonl",
}

## One result row shared by JSON, JSONL, and human output.
export type ResultRow = {
  schema_version: Int,
  kind: Str,
  run_id: Str,
  host: Str,
  resource: Str,
  phase: Str,
  outcome: outcome.Outcome,
  verified: Bool,
  cause: Str,
  duration_ms: Int,
}

## The final summary of one run.
export type Summary = {
  schema_version: Int,
  kind: Str,
  run_id: Str,
  hosts: List[Str],
  unchanged: Int,
  changed: Int,
  skipped: Int,
  blocked: Int,
  failed: Int,
  unknown: Int,
  partial: Int,
  exit: Int,
}

## A complete report: ordered rows and their summary.
export type Report = {
  schema_version: Int,
  kind: Str,
  run_id: Str,
  results: List[ResultRow],
  summary: Summary,
}

## Builds one result row.
export pure row(
  run_id: Str,
  host: Str,
  resource: Str,
  phase: Str,
  value: outcome.Outcome,
  verified: Bool,
  cause: Str,
  duration_ms: Int,
) -> ResultRow {
  ResultRow(
    schema_version: SCHEMA_VERSION,
    kind: "result",
    run_id: run_id,
    host: host,
    resource: resource,
    phase: phase,
    outcome: value,
    verified: verified,
    cause: cause,
    duration_ms: duration_ms,
  )
}

pure unique_hosts(rows: List[ResultRow]) -> List[Str] {
  var hosts: List[Str] = []
  for entry in rows {
    if ! (entry.host in hosts) {
      hosts += [entry.host]
    }
  }

  hosts
}

## Builds the summary for a list of rows and a command exit code.
export pure summarize(run_id: Str, rows: List[ResultRow], exit_code: Int) -> Summary {
  var outcomes: List[outcome.Outcome] = []
  for entry in rows {
    outcomes += [entry.outcome]
  }

  let totals = outcome.counts(outcomes)
  Summary(
    schema_version: SCHEMA_VERSION,
    kind: "summary",
    run_id: run_id,
    hosts: unique_hosts(rows),
    unchanged: totals.unchanged,
    changed: totals.changed,
    skipped: totals.skipped,
    blocked: totals.blocked,
    failed: totals.failed,
    unknown: totals.unknown,
    partial: totals.partial,
    exit: exit_code,
  )
}

## Builds a complete report.
export pure build(run_id: Str, rows: List[ResultRow], exit_code: Int) -> Report {
  Report(
    schema_version: SCHEMA_VERSION,
    kind: "report",
    run_id: run_id,
    results: rows,
    summary: summarize(run_id, rows, exit_code),
  )
}

pure sanitize(text: Str) -> Str {
  CONTROL.replace(text, with: "?")
}

pure utf8_boundary(value: Str, limit: Int) -> Int {
  var cut = limit
  while cut > 0 {
    let byte = value.byte_at(cut) ?? 0
    if byte < 128 or byte >= 192 {
      break
    }
    cut -= 1
  }
  cut
}

pure safe(text: Str, redactor: redact.Redactor) -> Str {
  let cleaned = sanitize(redact.redact(text, redactor))
  if cleaned.byte_len() > MAX_FIELD_BYTES {
    let cut = utf8_boundary(cleaned, MAX_FIELD_BYTES)
    return cleaned.byte_slice(0, cut) + "...[truncated]"
  }
  cleaned
}

## Keeps the primary failure when cleanup also failed.
export pure primary_failure(primary: Str, cleanup: Str) -> Str {
  let _ = cleanup
  primary
}

## Sanitizes and redacts one free-form message for diagnostics.
export pure clean(text: Str, redactor: redact.Redactor) -> Str {
  safe(text, redactor)
}

pure scrub(entry: ResultRow, redactor: redact.Redactor) -> ResultRow {
  ResultRow(
    schema_version: entry.schema_version,
    kind: entry.kind,
    run_id: safe(entry.run_id, redactor),
    host: safe(entry.host, redactor),
    resource: safe(entry.resource, redactor),
    phase: safe(entry.phase, redactor),
    outcome: entry.outcome,
    verified: entry.verified,
    cause: safe(entry.cause, redactor),
    duration_ms: entry.duration_ms,
  )
}

pure scrub_summary(summary: Summary, redactor: redact.Redactor) -> Summary {
  var hosts: List[Str] = []
  for host in summary.hosts {
    hosts += [safe(host, redactor)]
  }

  Summary(
    schema_version: summary.schema_version,
    kind: summary.kind,
    run_id: safe(summary.run_id, redactor),
    hosts: hosts,
    unchanged: summary.unchanged,
    changed: summary.changed,
    skipped: summary.skipped,
    blocked: summary.blocked,
    failed: summary.failed,
    unknown: summary.unknown,
    partial: summary.partial,
    exit: summary.exit,
  )
}

pure scrub_report(report: Report, redactor: redact.Redactor) -> Report {
  var rows: List[ResultRow] = []
  for entry in report.results {
    rows += [scrub(entry, redactor)]
  }

  Report(
    schema_version: report.schema_version,
    kind: report.kind,
    run_id: safe(report.run_id, redactor),
    results: rows,
    summary: scrub_summary(report.summary, redactor),
  )
}

## Renders a human-readable table and summary line.
export pure human(report: Report, redactor: redact.Redactor) -> Str {
  let scrubbed = scrub_report(report, redactor)
  var lines: List[Str] = []
  lines += ["HOST\tRESOURCE\tPHASE\tOUTCOME\tVERIFIED\tCAUSE"]
  for entry in scrubbed.results {
    lines += [
      f"{entry.host}\t{entry.resource}\t{entry.phase}\t{outcome.wire(entry.outcome)}\t{entry.verified}\t{entry.cause}",
    ]
  }

  let summary = scrubbed.summary
  lines += [
    f"hosts={summary.hosts.join(",")} unchanged={summary.unchanged} changed={summary.changed} skipped={summary.skipped} blocked={summary.blocked} failed={summary.failed} unknown={summary.unknown} partial={summary.partial} exit={summary.exit}",
  ]
  lines.join("\n") + "\n"
}

## Renders the schema-version-1 JSON object.
export pure render_json(report: Report, redactor: redact.Redactor) -> Result[Str, Error] {
  let scrubbed = scrub_report(report, redactor)
  let encoded = json.encode(scrubbed, pretty: false)?
  Ok(encoded + "\n")
}

## Renders JSONL result lines followed by the summary line.
export pure render_jsonl(report: Report, redactor: redact.Redactor) -> Result[Str, Error] {
  let scrubbed = scrub_report(report, redactor)
  var values: List[Any] = []
  for entry in scrubbed.results {
    values += [entry]
  }
  values += [scrubbed.summary]
  let encoded = json.encode_lines(values)?
  if encoded.ends_with("\n") {
    Ok(encoded)
  } else {
    Ok(encoded + "\n")
  }
}

## Renders one report in the selected style.
export pure render(report: Report, style: Style, redactor: redact.Redactor) -> Result[Str, Error] {
  match style {
    Human => Ok(human(report, redactor)),
    Json => render_json(report, redactor),
    Jsonl => render_jsonl(report, redactor),
  }
}
