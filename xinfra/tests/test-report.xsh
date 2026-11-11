use infra.compare
use infra.report

pure entry(host: Str, id: Str, status: Str, act: Str? = null, detail: Str? = null) -> report.Entry {
  report.Entry(
    host:,
    id:,
    kind: "file",
    status:,
    act:,
    changes: [compare.Change(field: "mode", from: "0644", to: "0600")],
    conditional: false,
    phase: null,
    detail:,
    verified: null,
  )
}

pure scenario(mode: Str, entries: List[report.Entry], ok: Bool = true) -> report.Report {
  report.Report(mode:, hosts: [report.HostReport(host: "web-1", ok:, phase: null, detail: null, entries:)])
}

test terminal_control_sequences_from_a_host_are_neutralized {
  let hostile = "bad\u{1b}[2J\u{1b}]0;title\u{7}\r\u{9b}31m ok\nnext\tline"
  let clean = report.sanitize(hostile)
  assert "\u{1b}" not in clean
  assert "\u{7}" not in clean
  assert "\r" not in clean
  assert "\u{9b}" not in clean
  assert "ok\nnext\tline" in clean
}

test secrets_are_replaced_wherever_they_appear {
  let text = report.redact("token=hunter22 and hunter22 again; other=safe", ["hunter22", ""])
  assert text == "token=*** and *** again; other=safe"
}

test text_output_shows_only_what_needs_attention_by_default {
  let shown = report.text(scenario("plan", [entry("web-1", "quiet", "satisfied"), entry("web-1", "motd", "drift", act: "update")]), false)
  assert "motd" in shown
  assert "mode: 0644 -> 0600" in shown
  assert "quiet" not in shown
  let verbose = report.text(scenario("plan", [entry("web-1", "quiet", "satisfied")]), true)
  assert "quiet" in verbose
}

test text_output_is_sanitized_after_assembly {
  let nasty = entry("web-1", "motd", "failed", detail: "boom\u{1b}[31m")
  assert "\u{1b}" not in report.text(scenario("apply", [nasty]), false)
}

test exit_status_distinguishes_drift_from_trouble {
  assert report.exit_status(scenario("plan", [entry("web-1", "a", "drift", act: "create")])) == 0
  assert report.exit_status(scenario("check", [entry("web-1", "a", "satisfied")])) == 0
  assert report.exit_status(scenario("check", [entry("web-1", "a", "drift", act: "create")])) == 1
  assert report.exit_status(scenario("check", [entry("web-1", "a", "drift"), entry("web-1", "b", "uncertain")])) == 3
  assert report.exit_status(scenario("apply", [entry("web-1", "a", "changed")])) == 0
  for status in ["failed", "partial", "unknown", "conflict", "uncertain"] {
    assert report.exit_status(scenario("apply", [entry("web-1", "a", status)])) == 3, status
  }
  assert report.exit_status(scenario("apply", [], ok: false)) == 3
}

test json_lines_are_one_valid_object_per_line_with_a_summary {
  let lines = report.json_lines(scenario("plan", [entry("web-1", "a", "drift", act: "update"), entry("web-1", "b", "satisfied")]))?.lines()
  assert lines.len() == 3
  for line in lines {
    let decoded = json.decode(line)?.require(Record)?
    assert "type" in decoded.keys()
  }
  let first = json.decode(lines[0])?.require(Record)?
  assert first.get("type")?.require(Str)? == "entry"
  assert first.get("host")?.require(Str)? == "web-1"
  assert first.get("act")?.require(Str)? == "update"
  let last = json.decode(lines[2])?.require(Record)?
  assert last.get("type")?.require(Str)? == "summary"
  assert last.get("exit")?.require(Int)? == 0
}

test json_documents_keep_changes_as_structured_data {
  let document = json.decode(report.json_document(scenario("check", [entry("web-1", "a", "drift")]))?)?.require(Record)?
  let hosts = document.get("hosts")?.require(List[Record])?
  let entries = hosts[0].get("entries")?.require(List[Record])?
  let changes = entries[0].get("changes")?.require(List[Record])?
  assert changes[0].get("field")?.require(Str)? == "mode"
}
