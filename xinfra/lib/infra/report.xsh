##! What plan, check and apply tell the operator. A report is plain data: one
##! entry per host and resource with its phase and cause, rendered as text,
##! JSON or JSON Lines. Text from hosts is untrusted, so control sequences are
##! removed before it is shown, and known secret values are replaced.

use infra.compare

## One resource on one host. `status` is a verdict name for plan and check
## (`satisfied`, `drift`, `conflict`, `uncertain`, `not-evaluated`) and an
## outcome name for apply (`unchanged`, `changed`, `skipped`, `blocked`,
## `failed`, `partial`, `unknown`).
export type Entry = {
  host: Str,
  id: Str,
  kind: Str,
  status: Str,
  act: Str?,
  changes: List[compare.Change],
  conditional: Bool,
  phase: Str?,
  detail: Str?,
  verified: Bool?,
}

## One host: whether it could be worked on at all, and its entries in order.
export type HostReport = {
  host: Str,
  ok: Bool,
  phase: Str?,
  detail: Str?,
  entries: List[Entry],
}

## The result of a run across hosts.
export type Report = {mode: Str, hosts: List[HostReport]}

const control = rx"[\x00-\x08\x0B-\x1F\x7F\x{80}-\x{9F}]"

## Replace every control character except newline and tab with `?`, so text
## from a host cannot drive the operator's terminal.
export pure sanitize(text: Str) -> Str {
  control.replace(text, with: "?")
}

## Replace each secret value in `text` with `***`.
export pure redact(text: Str, secrets: List[Str]) -> Str {
  var result = text
  for secret in secrets {
    if secret != "" {
      result = result.replace(secret, with: "***")
    }
  }

  result
}

pure entries_of(report: Report) -> List[Entry] {
  report.hosts |> flat-map { |host| host.entries } |> collect()
}

pure has_status(entries: List[Entry], status: Str) -> Bool {
  entries |> any { |entry| entry.status == status }
}

pure needing_attention(entries: List[Entry]) -> Bool {
  entries |> any { |entry| attention(entry) }
}

pure with_status(entries: List[Entry], status: Str) -> Int {
  entries |> where { |entry| entry.status == status } |> count()
}

pure failed_hosts(report: Report) -> List[HostReport] {
  report.hosts |> where { |host| ! host.ok } |> collect()
}

pure attention(entry: Entry) -> Bool {
  let status = entry.status
  if status == "uncertain" {
    return ! entry.conditional
  }

  status == "failed" or status == "partial" or status == "unknown" or status == "conflict"
}

## The process exit status for a report: 0 when nothing needs attention, 1 for
## drift found by `check`, and 3 when a host failed, an outcome was failed,
## partial or unknown, or a fact could not be established.
export pure exit_status(report: Report) -> Int {
  let entries = entries_of(report)
  if ! failed_hosts(report).is_empty() or needing_attention(entries) {
    3
  } else if report.mode == "check" and has_status(entries, "drift") {
    1
  } else {
    0
  }
}

pure change_line(change: compare.Change) -> Str {
  f"      {change.field}: {change.from} -> {change.to}"
}

pure label(entry: Entry) -> Str {
  let act = entry.act ?? ""
  let marker = if entry.conditional { " (conditional)" } else { "" }
  if act == "" { f"{entry.status}{marker}" } else { f"{entry.status}: {act}{marker}" }
}

pure entry_lines(entry: Entry, verbose: Bool) -> List[Str] {
  let quiet = entry.status == "satisfied" or entry.status == "unchanged"
  if quiet and ! verbose {
    return []
  }

  var lines = [f"  {entry.id} [{entry.kind}] {label(entry)}"]
  let phase = entry.phase ?? ""
  let detail = entry.detail ?? ""
  if detail != "" {
    let where_ = if phase == "" { "" } else { f" ({phase})" }
    lines += [f"      {detail}{where_}"]
  }

  for change in entry.changes {
    lines += [change_line(change)]
  }

  lines
}

pure host_lines(host: HostReport, verbose: Bool) -> List[Str] {
  var lines = [f"{host.host}: {if host.ok { "ok" } else { "FAILED" }}"]
  if host.phase != null {
    lines += [f"  {host.phase}: {host.detail ?? ""}"]
  }

  for entry in host.entries {
    lines += entry_lines(entry, verbose)
  }

  lines
}

## Render a report for a terminal. Quiet entries are omitted unless `verbose`.
export pure text(report: Report, verbose: Bool) -> Str {
  var lines: List[Str] = []
  for host in report.hosts {
    lines += host_lines(host, verbose)
  }

  let entries = entries_of(report)
  let drift = with_status(entries, "drift")
  let changed = with_status(entries, "changed")
  let bad = entries |> where { |entry| attention(entry) } |> count()
  lines += [f"{report.mode}: {report.hosts.len()} host(s), {entries.len()} resource(s), {drift} drift, {changed} changed, {bad} need attention, {failed_hosts(report).len()} host(s) failed"]
  sanitize(lines.join("\n"))
}

## Render a report as one JSON document with sorted keys.
export pure json_document(report: Report) -> Result[Str, Error] {
  json.encode(report, pretty: true)
}

## Render a report as JSON Lines: one object per host failure or entry, then a
## final summary object.
export pure json_lines(report: Report) -> Result[Str, Error] {
  var lines: List[Str] = []
  for host in report.hosts {
    if ! host.ok {
      lines += [json.encode({type: "host", mode: report.mode, host: host.host, ok: false, phase: host.phase, detail: host.detail})?]
    }

    for entry in host.entries {
      lines += [json.encode({...entry, type: "entry", mode: report.mode})?]
    }
  }

  lines += [json.encode({type: "summary", mode: report.mode, hosts: report.hosts.len(), exit: exit_status(report)})?]
  Ok(lines.join("\n"))
}
