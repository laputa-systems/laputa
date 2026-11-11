##! Behavior coverage for persistent, bounded, redacted diagnostics.
use system.diagnostics

const SENTINEL = "test-only-diagnostics-sentinel-9f4c"

proc clock(boot_id: Str) -> diagnostics.DiagnosticClock {
  {boot_id, boottime_ns: 9100000000, wall_ns: 1760000000000000000}
}

proc service_list(names: List[Str]) -> List[diagnostics.ServiceState] {
  [{name, state: "running", restarts: 0} for name in names]
}

proc marker(generation: Str, serial: Int, failed: Str, names: List[Str]) -> Str {
  json.encode({
    format: diagnostics.DIAGNOSTICS_BOOT_FORMAT,
    generation_id: generation,
    boot_serial: serial,
    failed_generation: failed,
    root_digest: bytes.from_text(generation).sha256().hex(),
    profile: "qemu-maintained",
    services: service_list(names),
  })?
}

proc sources(root: Path) -> diagnostics.DiagnosticSources {
  {
    logger: fp"{root}/logger",
    boot_markers: fp"{root}/markers",
    running_generation: fp"{root}/generation.json",
    health: fp"{root}/health.json",
    lease_status: fp"{root}/lease.json",
    service_dir: fp"{root}/services",
    kmsg: "",
  }
}

proc seed_sources(root: Path) {
  root.mkdir()
  fp"{root}/generation.json".write(json.encode({profile: "qemu-maintained", generation_sha256: bytes.from_text("a").sha256().hex()})? + "\n")
  fp"{root}/health.json".write(json.encode({profile: "qemu-maintained", root_digest: bytes.from_text("a").sha256().hex()})? + "\n")
  fp"{root}/lease.json".write(json.encode({state: "bound", address: "192.0.2.10", prefix: 24, client_id: SENTINEL})? + "\n")
  fp"{root}/markers".write_lines([
    marker("b", 1, "", ["logger", "dhcp-eth0"]),
    marker("b", 2, "", ["logger", "dhcp-eth0"]),
    marker("a", 2, "b", ["logger", "dhcp-eth0", "dropbear"]),
    "not a marker",
  ])
  fp"{root}/logger".write_lines([
    f"event=test token={SENTINEL} lease=bound",
    "seq=1 source=socket severity=info tag=dhcpc msg=\"bound\"",
  ])
  fp"{root}/services".mkdir()
  fp"{root}/services/logger.json".write(json.encode({name: "logger", state: "running", restarts: 1})? + "\n")
  fp"{root}/services/dhcp.json".write(json.encode({name: "dhcp-eth0", state: "running", restarts: 0})? + "\n")
}

test test_redaction_removes_secret_shapes_and_keeps_context [error] {
  let text = f"event=boot token={SENTINEL} password: hunter2 Authorization: Bearer abc123 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"
  let redacted = diagnostics.diagnostics_redact(text)
  for secret in [SENTINEL, "hunter2", "abc123", "AAAAC3NzaC1lZDI1NTE5"] {
    assert secret not in redacted
  }
  assert "event=boot" in redacted
  assert "[redacted]" in redacted
}

test test_trim_keeps_newest_lines_within_both_bounds [error] {
  let lines = ["a", "bb", "ccc", "dddd"]
  assert diagnostics.diagnostics_trim(lines, 2, 100) == ["ccc", "dddd"]
  assert diagnostics.diagnostics_trim(lines, 100, 5) == ["dddd"]
  assert diagnostics.diagnostics_trim(lines, 100, 0).is_empty()
  assert diagnostics.diagnostics_trim(lines, 0, 100).is_empty()
}

test test_boot_history_extracts_identity_and_service_states [error] {
  let history = diagnostics.diagnostics_boot_history([
    marker("b", 1, "", ["logger", "dhcp-eth0"]),
    marker("a", 2, "b", ["dropbear", "logger"]),
    "not a marker",
  ], 20)
  assert history.invalid == 1
  assert history.entries.len() == 2
  assert history.entries[0].generation_id == "b"
  assert history.entries[1].failed_generation == "b"
  assert history.entries[1].services[0].name == "dropbear"
  assert history.entries[1].services[1].name == "logger"
}

test test_boot_history_keeps_only_the_newest_limit [error] {
  let lines = [marker(f"g{index}", index, "", ["logger"]) for index in range(0, 25)]
  let history = diagnostics.diagnostics_boot_history(lines, 20)
  assert history.entries.len() == 20
  assert history.entries[0].generation_id == "g5"
  assert history.entries[19].generation_id == "g24"
}

test test_lease_projects_only_bound_identity [error] {
  let bound = diagnostics.diagnostics_lease({
    state: "bound",
    address: "192.0.2.10",
    prefix: 24,
    client_id: SENTINEL,
    server: "192.0.2.1",
  })
  assert bound.state == "bound"
  assert bound.address == "192.0.2.10"
  assert bound.prefix == 24
  let pending = diagnostics.diagnostics_lease({state: "renewing", address: "192.0.2.10", prefix: 24})
  assert pending.state == "renewing"
  assert pending.address == ""
  assert pending.prefix == null
}

test test_collection_persists_identity_history_and_no_secret [fs, process, net, error] { |ctx|
  let root = test.temp_dir(ctx, name: "diagnostics-collect")?
  seed_sources(root)
  let store = fp"{root}/store"
  let result = diagnostics.diagnostics_collect(store, sources(root), clock("boot-1"), [
    "LAPUTA_GENERATION_ID=a",
    "LAPUTA_BOOT_SERIAL=2",
    "LAPUTA_FAILED_GENERATION=b",
  ])?
  assert result.boot.generation_id == "a"
  assert result.boot.boot_serial == 2
  assert result.boot.failed_generation == "b"
  assert result.history.len() == 3
  assert result.services.len() == 2
  assert result.bytes <= diagnostics.MAX_EVENT_BYTES

  let events = fp"{store}/{diagnostics.EVENTS_NAME}".read_text()?
  assert SENTINEL not in events
  assert "activation|b|1|" in events
  assert "activation|a|2|b" in events
  assert "lease|" in events
  assert "syslog|" in events
  assert "service|" in events

  let again = diagnostics.diagnostics_collect(store, sources(root), clock("boot-1"), [
    "LAPUTA_GENERATION_ID=a",
    "LAPUTA_BOOT_SERIAL=2",
    "LAPUTA_FAILED_GENERATION=b",
  ])?
  assert again.appended == 0
  assert again.total == result.total
}

test test_event_retention_stays_within_the_declared_caps [fs, process, net, error] { |ctx|
  let root = test.temp_dir(ctx, name: "diagnostics-retention")?
  seed_sources(root)
  let store = fp"{root}/store"
  store.mkdir()
  let padding = bytes.zero(200)?.utf8() ?? ""
  let old_events = [
    json.encode({
      format: diagnostics.DIAGNOSTICS_EVENT_FORMAT,
      key: f"old|{index}",
      boot_id: "old",
      boottime_ns: index,
      wall_ns: index,
      generation_id: "a",
      boot_serial: 0,
      failed_generation: "",
      kind: "syslog",
      detail: padding,
    })?
    for index in range(0, diagnostics.MAX_EVENT_LINES + 100)
  ]
  fp"{store}/{diagnostics.EVENTS_NAME}".write_lines(old_events)
  let result = diagnostics.diagnostics_collect(store, sources(root), clock("boot-2"), [])?
  assert result.total <= diagnostics.MAX_EVENT_LINES
  let lines = fp"{store}/{diagnostics.EVENTS_NAME}".read_lines()?
  assert lines.len() <= diagnostics.MAX_EVENT_LINES
  assert fp"{store}/{diagnostics.EVENTS_NAME}".metadata()?.size <= diagnostics.MAX_EVENT_BYTES
  assert "activation|a|2|b" in fp"{store}/{diagnostics.EVENTS_NAME}".read_text()?
}

test test_failed_event_write_preserves_the_existing_path [fs, process, net, error] { |ctx|
  let root = test.temp_dir(ctx, name: "diagnostics-write-failure")?
  seed_sources(root)
  let store = fp"{root}/store"
  store.mkdir()
  let blocked = fp"{store}/{diagnostics.EVENTS_NAME}"
  blocked.mkdir()
  fp"{blocked}/kept".write("prior state\n")
  let result = diagnostics.diagnostics_collect(store, sources(root), clock("boot-3"), [])?
  assert ! result.degraded.is_empty()
  assert blocked.is_dir()?
  assert fp"{blocked}/kept".read_text()? == "prior state\n"
}

test test_bundle_is_bounded_and_omits_unavailable_reports [fs, process, net, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "diagnostics-bundle")?
  seed_sources(root)
  let store = fp"{root}/store"
  let reading = clock("boot-4")
  let collected = diagnostics.diagnostics_collect(store, sources(root), reading, [
    "LAPUTA_GENERATION_ID=a",
    "LAPUTA_BOOT_SERIAL=2",
    "LAPUTA_FAILED_GENERATION=b",
  ])?
  let result = diagnostics.diagnostics_bundle(
    store,
    ["/bin/false", "false"],
    ["identity", "kernel"],
    reading,
    collected,
    SENTINEL,
  )?
  assert ! result.secret_present
  assert result.bytes > 0
  assert result.bytes <= diagnostics.MAX_BUNDLE_BYTES
  assert "events.log" in result.files.join(",")
  assert "manifest.json" in result.files.join(",")
  assert "identity" in result.omitted
  assert "kernel" in result.omitted
  let archive_entries = archive.list(fp"{store}/{diagnostics.BUNDLE_NAME}", .Tar, compression: .Gzip)? |> map .path.display() |> collect
  assert archive_entries.len() >= 3
  assert "events.log" in archive_entries.join(",")
  assert "manifest.json" in archive_entries.join(",")
  for name in archive_entries {
    assert SENTINEL not in name
  }
}

test test_bundle_scrubs_a_leaked_canary_from_report_output [fs, process, net, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "diagnostics-canary")?
  seed_sources(root)
  let store = fp"{root}/store"
  let reading = clock("boot-5")
  let collected = diagnostics.diagnostics_collect(store, sources(root), reading, [])?
  let fake = fp"{root}/fake-report.xsh"
  fake.write(f"""#!/bin/xsh
proc main(...argv: List[Str]) {{
  print f"{{{{\"format\":\"system-report-v1\",\"value\":\"{SENTINEL}\"}}}}"
}}
""")
  let xsh = process.which("xsh")?
  let result = diagnostics.diagnostics_bundle(
    store,
    [xsh.display(), fake.display()],
    ["identity"],
    reading,
    collected,
    SENTINEL,
  )?
  assert ! result.secret_present
  assert result.bytes > 0
  let report = fp"{store}/{diagnostics.STAGING_NAME}/system-report-identity.json"
  assert ! report.exists()?
}

test test_bundle_detects_a_canary_that_reached_the_events_file [fs, process, net, time, error] { |ctx|
  let root = test.temp_dir(ctx, name: "diagnostics-canary-events")?
  seed_sources(root)
  let store = fp"{root}/store"
  let reading = clock("boot-6")
  let collected = diagnostics.diagnostics_collect(store, sources(root), reading, [])?
  fp"{store}/{diagnostics.EVENTS_NAME}".write(f"leaked {SENTINEL}\n")
  let result = diagnostics.diagnostics_bundle(store, ["/bin/false", "false"], [], reading, collected, SENTINEL)?
  assert result.secret_present
  assert result.bytes == 0
  assert ! fp"{store}/{diagnostics.BUNDLE_NAME}".exists()?
}

test test_store_bytes_reports_only_regular_files [fs, error] { |ctx|
  let root = test.temp_dir(ctx, name: "diagnostics-store-bytes")?
  let store = fp"{root}/store"
  store.mkdir()
  fp"{store}/a".write("12345")
  fp"{store}/b".write("123")
  assert diagnostics.diagnostics_store_bytes(store)? == 8
  assert diagnostics.diagnostics_store_bytes(fp"{root}/missing")? == 0
}
