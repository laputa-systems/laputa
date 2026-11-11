##! Persistent, bounded diagnostics on the maintained state disk.
##!
##! One collection records boot identity, activation/failure history, service
##! state, lease changes, kernel records, and the syslog stream that xinit
##! already captures. A support bundle reuses the XSH system-report collectors
##! and carries only bounded, redacted files.
##!
##! The store is not a lossless log. The syslog receiver drops datagrams from a
##! full socket queue, by rate, by size, and at a blocked sink; the kernel ring
##! loses records a slow reader misses; xinit rotates its capture by
##! copy-truncate, so a write between copy and truncate can disappear. Here the
##! newest bounded prefix is kept and a failed write leaves the previous file
##! intact. No fleet observability layer is implied.

use lib.syslog_kmsg as kmsg

## The store and bundle format.
## Version of the diagnostics store format.
export const DIAGNOSTICS_FORMAT = "laputa-diagnostics-1"
## Version of one persisted event record.
export const DIAGNOSTICS_EVENT_FORMAT = "laputa-diagnostics-event-1"
## Version of the support-bundle manifest.
export const DIAGNOSTICS_BUNDLE_FORMAT = "laputa-diagnostics-bundle-1"
## Version of the health reporter boot marker.
export const DIAGNOSTICS_BOOT_FORMAT = "laputa-boot-marker-1"

## Defaults on the maintained state disk.
## The maintained state-disk store root.
export const DEFAULT_STORE = p"/var/log/diagnostics"
## Bounded event-log file name.
export const EVENTS_NAME = "events.log"
## Bounded activation-history file name.
export const BOOT_HISTORY_NAME = "boot-history.json"
## Last observed lease file name.
export const LEASE_NAME = "lease.json"
## Published support-bundle file name.
export const BUNDLE_NAME = "support.tar.gz"
## Exclusive collector lock file name.
export const LOCK_NAME = ".lock"
## Support-bundle staging directory name.
export const STAGING_NAME = ".bundle"

## Storage bounds. The sum stays inside MAX_STORE_BYTES.
## Event-log byte cap.
export const MAX_EVENT_BYTES = 65536
## Event-log line cap.
export const MAX_EVENT_LINES = 512
## Activation-history entry cap.
export const MAX_BOOT_HISTORY = 20
## Per-source read cap.
export const MAX_SOURCE_BYTES = 65536
## Captured syslog lines per collection cap.
export const MAX_SYSLOG_LINES = 256
## Kernel records per collection cap.
export const MAX_KMSG_RECORDS = 64
## Per-section system-report cap.
export const MAX_REPORT_BYTES = 32768
## Published bundle byte cap.
export const MAX_BUNDLE_BYTES = 262144
## Bundle staging byte cap before the tar header overhead.
export const MAX_BUNDLE_STAGING_BYTES = 245760
## Whole-store byte cap.
export const MAX_STORE_BYTES = 393216
## Persisted-lease byte cap.
export const MAX_LEASE_BYTES = 2048
## Per-event detail byte cap.
export const MAX_DETAIL_BYTES = 2048

## Sensitive assignments never enter the event log. The whole payload after a
## secret-shaped key is replaced, including quoted or unquoted values.
## Replacement text for a redacted value.
export const REDACTED = "[redacted]"

const SECRET_ASSIGNMENT = rx"(?i)(password|passwd|passphrase|secret|token|api[_-]?key|private[_-]?key|authorized[_-]?keys?|tskey|credential|masterkey)[ \t]*[=:][ \t]*[^ \t]+"
const BEARER = rx"(?i)(authorization[ \t]*:[ \t]*bearer)[ \t]+[^ \t]+"
const SSH_KEY = rx"(?i)(ssh-(rsa|ed25519|dss))[ \t]+[A-Za-z0-9+/=]+"

## One clock reading. `boottime_ns` is comparable only inside `boot_id`;
## `wall_ns` may precede or follow a clock step before time sync.
export type DiagnosticClock = {boot_id: Str, boottime_ns: Int, wall_ns: Int}

## One named service observation.
export type ServiceState = {name: Str, state: Str, restarts: Int}

## The lease fields safe to persist: no client identifier, server id, or raw file.
export type LeaseState = {state: Str, address: Str, prefix: Int?}

## Parsed boot-marker history and the lines that did not validate.
export type BootHistory = {entries: List[BootHistoryEntry], invalid: Int}

## One boot marker reduced to activation identity and service history.
export type BootHistoryEntry = {
  generation_id: Str,
  boot_serial: Int,
  failed_generation: Str,
  profile: Str,
  root_digest: Str,
  services: List[ServiceState],
}

## One persisted diagnostic record. `key` makes a repeated collection idempotent.
export type DiagnosticEvent = {
  format: Str,
  key: Str,
  boot_id: Str,
  boottime_ns: Int,
  wall_ns: Int,
  generation_id: Str,
  boot_serial: Int,
  failed_generation: Str,
  kind: Str,
  detail: Str,
}

## The process-visible sources; tests replace them with fixtures.
export type DiagnosticSources = {
  logger: Path,
  boot_markers: Path,
  running_generation: Path,
  health: Path,
  lease_status: Path,
  service_dir: Path,
  kmsg: Str,
}

## What one collection wrote and what it could not.
export type CollectResult = {
  existing: Int,
  appended: Int,
  total: Int,
  bytes: Int,
  degraded: List[Str],
  history: List[BootHistoryEntry],
  boot: DiagnosticEvent,
  services: List[ServiceState],
}

## One collected system-report section.
export type ReportFile = {section: Str, name: Str, bytes: Int, state: Str}

## The optional file one system-report section produced.
export type ReportOutcome = {file: ReportFile?, degraded: List[Str]}

## Kernel records from one bounded ring read.
export type KernelRead = {events: List[DiagnosticEvent], degraded: List[Str], overruns: Int, malformed: Int}

## One support-bundle file in the manifest.
export type ManifestFile = {name: Str, bytes: Int, sha256: Str}

## What a support bundle contains.
export type BundleResult = {
  path: Path,
  bytes: Int,
  sha256: Str,
  files: List[Str],
  omitted: List[Str],
  degraded: List[Str],
  secret_present: Bool,
}

## The maintained guest sources.
export pure diagnostics_sources() -> DiagnosticSources {
  {
    logger: p"/var/log/logger/current",
    boot_markers: p"/var/log/boot-markers.log",
    running_generation: p"/run/laputa-running-generation.json",
    health: p"/run/laputa-health.json",
    lease_status: p"/run/dhcpc/eth0.status",
    service_dir: p"/run/xinit",
    kmsg: "/dev/kmsg",
  }
}

## Every bundle section except identity is optional under pressure.
export pure diagnostics_sections() -> List[Str] {
  ["identity", "kernel", "storage", "network", "processes"]
}

## The newest lines that fit both caps, oldest first.
export pure diagnostics_trim(lines: List[Str], max_lines: Int, max_bytes: Int) -> List[Str] {
  var count = 0
  let kept = collect {
    var index = lines.len()
    var byte_total = 0
    while index > 0 and count < max_lines {
      index -= 1
      let line = lines[index]
      let cost = line.byte_len() + 1
      break when byte_total + cost > max_bytes
      yield line
      count += 1
      byte_total += cost
    }
  }
  collect {
    var at = kept.len()
    while at > 0 {
      at -= 1
      yield kept[at]
    }
  }
}

## The first value named by `key` in a split command line, or empty.
export pure diagnostics_cmdline_value(words: List[Str], key: Str) -> Str {
  var found = ""
  for word in words {
    if word.starts_with(key) and found == "" {
      found = word.replace(key, with: "")
    }
  }
  found
}

## Replace sensitive assignments, bearer credentials, and key material.
export pure diagnostics_redact(text: Str) -> Str {
  let assigned = SECRET_ASSIGNMENT.replace(text, with: f"$1={REDACTED}")
  let bearer = BEARER.replace(assigned, with: f"$1 {REDACTED}")
  SSH_KEY.replace(bearer, with: f"$1 {REDACTED}")
}

## Clip one detail string without ever splitting a multi-byte character.
export pure diagnostics_clip(text: Str, limit: Int) -> Str {
  guard text.byte_len() > limit else { return text }
  var end = limit
  var steps = 0
  while end > 0 and steps < 3 and (text.byte_at(end) ?? 0) / 64 == 2 {
    end -= 1
    steps += 1
  }
  text[..end]
}

pure diagnostics_json_str(value: Any, json_path: List[Any], fallback: Str) -> Str {
  json.get(value, json_path, fallback).require(Str) ?? fallback
}

pure diagnostics_json_int(value: Any, json_path: List[Any], fallback: Int) -> Int {
  json.get(value, json_path, fallback).require(Int) ?? fallback
}

pure diagnostics_services(value: Any) -> List[ServiceState] {
  if let Ok(items) = json.get(value, ["services"], []).require(List[Any]) {
    let found = collect {
      for item in items {
        let name = diagnostics_json_str(item, ["name"], "")
        let state = diagnostics_json_str(item, ["state"], "")
        continue when name == "" or state == ""
        yield {
          name,
          state,
          restarts: diagnostics_json_int(item, ["restarts"], 0),
        }
      }
    }
    found |> sort-by .name |> collect
  } else {
    []
  }
}

## Reduce boot-marker JSON lines to the newest bounded activation history.
export pure diagnostics_boot_history(lines: List[Str], limit: Int) -> BootHistory {
  var entries: List[BootHistoryEntry] = []
  var invalid = 0
  for line in lines {
    let trimmed = line.trim()
    continue when trimmed == ""
    if let Ok(value) = json.decode(trimmed) {
      let format = diagnostics_json_str(value, ["format"], "")
      let generation = diagnostics_json_str(value, ["generation_id"], "")
      let serial = diagnostics_json_int(value, ["boot_serial"], -1)
      if format != DIAGNOSTICS_BOOT_FORMAT or generation == "" or serial < 0 {
        invalid += 1
      } else {
        entries += [{
          generation_id: generation,
          boot_serial: serial,
          failed_generation: diagnostics_json_str(value, ["failed_generation"], ""),
          profile: diagnostics_json_str(value, ["profile"], ""),
          root_digest: diagnostics_json_str(value, ["root_digest"], ""),
          services: diagnostics_services(value),
        }]
      }
    } else {
      invalid += 1
    }
  }
  if entries.len() > limit {
    entries = entries[entries.len() - limit..]
  }
  {entries, invalid}
}

## The bounded lease fields, defaulting to an unknown lease.
export pure diagnostics_lease(value: Any) -> LeaseState {
  let state = diagnostics_json_str(value, ["state"], "unknown")
  let address = diagnostics_json_str(value, ["address"], "")
  let prefix = json.get(value, ["prefix"], null).require(Int) ?? -1
  if state == "bound" and address != "" and prefix >= 0 {
    {state, address, prefix}
  } else {
    {state, address: "", prefix: null}
  }
}

## A stable key, so collecting twice in one boot does not duplicate records.
export pure diagnostics_event(
  key: Str,
  clock: DiagnosticClock,
  generation: Str,
  serial: Int,
  failed: Str,
  kind: Str,
  detail: Str,
) -> DiagnosticEvent {
  {
    format: DIAGNOSTICS_EVENT_FORMAT,
    key,
    boot_id: clock.boot_id,
    boottime_ns: clock.boottime_ns,
    wall_ns: clock.wall_ns,
    generation_id: generation,
    boot_serial: serial,
    failed_generation: failed,
    kind,
    detail: diagnostics_clip(detail, MAX_DETAIL_BYTES),
  }
}

pure diagnostics_event_key(value: Any) -> Str {
  diagnostics_json_str(value, ["key"], "")
}

proc diagnostics_source_lines(file_path: Path, max_lines: Int) {
  return Ok([]) unless file_path.exists()
  Ok(diagnostics_trim(file_path.read_lines()?, max_lines, MAX_SOURCE_BYTES))
}

proc diagnostics_replace(file_path: Path, text: Str) {
  atomically replace file_path as next {
    next.write(text, mode: 0o600)
    fs.fsync(next)
  }
  fs.fsync(file_path.parent())
}

## Walk the store without following links and sum the bytes it owns.
export proc diagnostics_store_bytes(store: Path) [fs, error] -> Result[Int, Error] {
  return Ok(0) unless store.exists()
  var total = 0
  for entry in fs.files(store, hidden: true)? {
    if entry.kind == "file" {
      total += entry.size
    }
  }
  Ok(total)
}

proc diagnostics_kernel(
  clock: DiagnosticClock,
  generation: Str,
  serial: Int,
  failed: Str,
  device: Str,
  degraded: List[Str],
) -> Result[KernelRead, Error] {
  var failures = degraded
  return Ok({events: [], degraded: failures, overruns: 0, malformed: 0}) when device == ""
  let opened = unix.open_fd(fp"{device}", nonblock: true)
  let descriptor = opened ?? {
    failures += [f"kmsg:open:{.errno ?? -1}"]
    return Ok({events: [], degraded: failures, overruns: 0, malformed: 0})
  }
  defer unix.close_fd(descriptor)
  let _ = unix.seek_fd(descriptor, 0, whence: "start")
  let batch = kmsg.drain({read: kmsg.device_read}, descriptor, MAX_KMSG_RECORDS)?
  if batch.overruns > 0 {
    failures += [f"kmsg:overrun:{batch.overruns}"]
  }
  if batch.malformed > 0 {
    failures += [f"kmsg:malformed:{batch.malformed}"]
  }
  let events = collect {
    for record in batch.records {
      let text = record.message.utf8() ?? ""
      let detail = f"kseq={record.sequence} ktime_us={record.microseconds} severity={record.severity} msg={diagnostics_redact(text)}"
      yield diagnostics_event(
        f"kernel|{clock.boot_id}|{record.sequence}",
        clock, generation, serial, failed, "kernel", detail,
      )
    }
  }
  Ok({events, degraded: failures, overruns: batch.overruns, malformed: batch.malformed})
}

## Persist one bounded collection and return what it stored.
export proc diagnostics_collect(
  store: Path,
  sources: DiagnosticSources,
  clock: DiagnosticClock,
  cmdline: List[Str],
) [fs, process, net, error] -> Result[CollectResult, Error] {
  let generation = diagnostics_cmdline_value(cmdline, "LAPUTA_GENERATION_ID=")
  let serial = diagnostics_cmdline_value(cmdline, "LAPUTA_BOOT_SERIAL=").parse_int() ?? 0
  let failed = diagnostics_cmdline_value(cmdline, "LAPUTA_FAILED_GENERATION=")
  var degraded = []
  match store.mkdir() {
    Ok(_) => {}
    Err(problem) => { degraded += [f"store:{problem.errno ?? -1}"] }
  }

  let events_path = fp"{store}/{EVENTS_NAME}"
  let history_path = fp"{store}/{BOOT_HISTORY_NAME}"
  let lease_path = fp"{store}/{LEASE_NAME}"

  var existing_lines = []
  if events_path.exists() {
    match events_path.read_lines() {
      Ok(lines) => { existing_lines = lines }
      Err(problem) => { degraded += [f"events:read:{problem.errno ?? -1}"] }
    }
  }
  var existing_keys = []
  for line in existing_lines {
    continue when line.trim() == ""
    if let Ok(value) = json.decode(line) {
      existing_keys += [diagnostics_event_key(value)]
    }
  }

  var source_lines = []
  match diagnostics_source_lines(sources.boot_markers, MAX_BOOT_HISTORY * 4) {
    Ok(lines) => { source_lines = lines }
    Err(problem) => { degraded += [f"markers:{problem.errno ?? -1}"] }
  }
  let history = diagnostics_boot_history(source_lines, MAX_BOOT_HISTORY)
  if history.invalid > 0 {
    degraded += [f"markers:invalid:{history.invalid}"]
  }

  var receipt: Any = null
  if let Ok(value) = json.read(sources.running_generation) {
    receipt = value
  }
  var health: Any = null
  if sources.health.exists() {
    match json.read(sources.health) {
      Ok(value) => { health = value }
      Err(problem) => { degraded += [f"health:{problem.errno ?? -1}"] }
    }
  }
  let profile = diagnostics_json_str(receipt, ["profile"], diagnostics_json_str(health, ["profile"], ""))
  let root_digest = diagnostics_json_str(receipt, ["generation_sha256"], diagnostics_json_str(health, ["root_digest"], ""))

  var services: List[ServiceState] = []
  if sources.service_dir.exists() {
    for entry in fs.children(sources.service_dir)? {
      continue unless entry.name.ends_with(".json")
      if let Ok(value) = json.read(entry.path) {
        let name = diagnostics_json_str(value, ["name"], "")
        let state = diagnostics_json_str(value, ["state"], "")
        if name != "" and state != "" {
          services += [{name, state, restarts: diagnostics_json_int(value, ["restarts"], 0)}]
        }
      }
    }
    services = services |> sort-by .name |> collect
  }
  let service_text = services |> map f"{.name}={.state}/{.restarts}" |> collect |> join(" ")

  var lease = LeaseState(state: "absent", address: "", prefix: null)
  var previous = LeaseState(state: "absent", address: "", prefix: null)
  if lease_path.exists() {
    if let Ok(value) = json.read(lease_path) {
      previous = diagnostics_lease(value)
    }
  }
  if sources.lease_status.exists() {
    match json.read(sources.lease_status) {
      Ok(value) => { lease = diagnostics_lease(value) }
      Err(problem) => { degraded += [f"lease:{problem.errno ?? -1}"] }
    }
  }

  let boot_detail = f"profile={profile} root_digest={root_digest} services={services.len()} markers={history.entries.len()} lease={lease.state}"
  var fresh = [
    diagnostics_event(f"boot|{clock.boot_id}", clock, generation, serial, failed, "boot", boot_detail),
  ]
  for entry in history.entries {
    let detail = f"generation={entry.generation_id} serial={entry.boot_serial} failed={entry.failed_generation} profile={entry.profile} services={entry.services.len()}"
    fresh += [diagnostics_event(
      f"activation|{entry.generation_id}|{entry.boot_serial}|{entry.failed_generation}",
      clock, entry.generation_id, entry.boot_serial, entry.failed_generation, "activation", detail,
    )]
  }
  if service_text != "" {
    fresh += [diagnostics_event(
      f"service|{clock.boot_id}|{hash.sha256(bytes.from_text(service_text)).hex()}",
      clock, generation, serial, failed, "service", service_text,
    )]
  }
  if lease.state != previous.state or lease.address != previous.address or lease.prefix != previous.prefix {
    let detail = f"state={lease.state} address={lease.address} prefix={lease.prefix ?? 0}"
    fresh += [diagnostics_event(
      f"lease|{clock.boot_id}|{hash.sha256(bytes.from_text(detail)).hex()}",
      clock, generation, serial, failed, "lease", detail,
    )]
  }

  let kernel = diagnostics_kernel(clock, generation, serial, failed, sources.kmsg, degraded)?
  degraded = kernel.degraded
  for event in kernel.events {
    fresh += [event]
  }

  let syslog_lines = diagnostics_source_lines(sources.logger, MAX_SYSLOG_LINES) ?? {
    degraded += [f"syslog:{.errno ?? -1}"]
    []
  }
  for line in syslog_lines {
    let detail = diagnostics_redact(line) |> diagnostics_clip(_, MAX_DETAIL_BYTES)
    fresh += [diagnostics_event(
      f"syslog|{clock.boot_id}|{hash.sha256(bytes.from_text(detail)).hex()}",
      clock, generation, serial, failed, "syslog", detail,
    )]
  }

  var added = []
  for event in fresh {
    continue when event.key in existing_keys
    added += [event]
    existing_keys += [event.key]
  }
  let all_lines = existing_lines |> where .trim() != "" |> collect
  let appended_lines = [json.encode(event)? for event in added]
  let bounded = diagnostics_trim(all_lines + appended_lines, MAX_EVENT_LINES, MAX_EVENT_BYTES)
  var stored = 0
  var byte_total = 0
  if ! (added.is_empty() and existing_lines.is_empty()) {
    let body = bounded.join("\n") + (if bounded.is_empty() { "" } else { "\n" })
    match diagnostics_replace(events_path, body) {
      Ok(_) => {
        stored = added.len()
        byte_total = body.byte_len()
      }
      Err(problem) => { degraded += [f"events:write:{problem.errno ?? -1}"] }
    }
  }

  let history_body = json.encode(history.entries)? + "\n"
  match diagnostics_replace(history_path, history_body) {
    Ok(_) => {}
    Err(problem) => { degraded += [f"history:write:{problem.errno ?? -1}"] }
  }
  if sources.lease_status.exists() {
    let lease_body = json.encode(lease)? + "\n"
    if lease_body.byte_len() <= MAX_LEASE_BYTES {
      match diagnostics_replace(lease_path, lease_body) {
        Ok(_) => {}
        Err(problem) => { degraded += [f"lease:write:{problem.errno ?? -1}"] }
      }
    } else {
      degraded += ["lease:oversize"]
    }
  }

  Ok({
    existing: existing_lines.len(),
    appended: stored,
    total: bounded.len(),
    bytes: byte_total,
    degraded,
    history: history.entries,
    boot: fresh[0],
    services,
  })
}

proc diagnostics_report_section(
  report_argv: List[Str],
  section: Str,
  staging: Path,
  degraded: List[Str],
) -> Result[ReportOutcome, Error] {
  var failures = degraded
  let name = f"system-report-{section}.json"
  let output = fp"{staging}/{name}"
  let errors = fp"{staging}/.report-{section}.err"
  let status = process.run(process.command_argv(
    report_argv[0],
    [@report_argv[1..], "--json", "--section", section],
    stdout: output,
    stderr: errors,
  ))?
  errors.remove()
  guard status.ok else {
    output.remove()
    failures += [f"report:{section}:status"]
    return Ok({file: null, degraded: failures})
  }
  let size = output.metadata()?.size
  if size > MAX_REPORT_BYTES {
    output.remove()
    failures += [f"report:{section}:oversize"]
    return Ok({file: null, degraded: failures})
  }
  Ok({file: {section, name, bytes: size, state: "kept"}, degraded: failures})
}

proc diagnostics_scrub(file_path: Path, canary: Str) {
  return when canary == "" or ! file_path.exists()
  let text = file_path.read_text()?
  if canary in text {
    file_path.write(text.replace(canary, with: REDACTED), mode: 0o600)
    fs.fsync(file_path)
  }
  Ok()
}

proc diagnostics_tree_contains(staging: Path, needle: Str) {
  return Ok(false) when needle == ""
  for entry in fs.files(staging, hidden: true)? {
    continue unless entry.kind == "file"
    if let Ok(text) = entry.path.read_text() {
      return Ok(true) when needle in text
    }
  }
  Ok(false)
}

## Build the bounded redacted support bundle. The previous bundle is only
## replaced after a new one is complete, so a full disk preserves the old one.
export proc diagnostics_bundle(
  store: Path,
  report_argv: List[Str],
  sections: List[Str],
  clock: DiagnosticClock,
  collected: CollectResult,
  canary: Str,
) [fs, process, time, error] -> Result[BundleResult, Error] {
  var degraded = []
  var omitted = []
  let staging = fp"{store}/{STAGING_NAME}"
  let bundle = fp"{store}/{BUNDLE_NAME}"
  let next = fp"{bundle}.next"
  staging.remove()
  match staging.mkdir() {
    Ok(_) => {}
    Err(problem) => {
      degraded += [f"staging:{problem.errno ?? -1}"]
      return Ok({path: bundle, bytes: 0, sha256: "", files: [], omitted, degraded, secret_present: false})
    }
  }

  for name in [EVENTS_NAME, BOOT_HISTORY_NAME, LEASE_NAME] {
    let source = fp"{store}/{name}"
    continue unless source.exists()
    match source.copy(to: fp"{staging}/{name}", overwrite: true) {
      Ok(_) => {}
      Err(problem) => { degraded += [f"copy:{name}:{problem.errno ?? -1}"] }
    }
  }

  for section in sections {
    let outcome = diagnostics_report_section(report_argv, section, staging, degraded)?
    degraded = outcome.degraded
    if let file = outcome.file {
      match diagnostics_scrub(fp"{staging}/{file.name}", canary) {
        Ok(_) => {}
        Err(problem) => { degraded += [f"scrub:{section}:{problem.errno ?? -1}"] }
      }
    } else {
      omitted += [section]
    }
  }

  var total = 0
  for entry in fs.files(staging, hidden: true)? {
    if entry.kind == "file" {
      total += entry.size
    }
  }
  let drop_order = ["processes", "network", "storage", "kernel", "identity"]
  for section in drop_order {
    guard total > MAX_BUNDLE_STAGING_BYTES else { break }
    let name = f"system-report-{section}.json"
    let path_value = fp"{staging}/{name}"
    if path_value.exists() {
      let size = path_value.metadata()?.size
      match path_value.remove() {
        Ok(_) => {
          total -= size
          omitted += [section]
        }
        Err(_) => {}
      }
    }
  }

  let secret = diagnostics_tree_contains(staging, canary)?
  if secret {
    staging.remove()
    return Ok({path: bundle, bytes: 0, sha256: "", files: [], omitted, degraded, secret_present: true})
  }

  let manifest_files = [
    {
      name: entry.name,
      bytes: entry.size,
      sha256: hash.sha256(entry.path)?.hex(),
    }
    for entry in fs.files(staging, hidden: true)?
    if entry.kind == "file"
  ]
  let manifest = {
    format: DIAGNOSTICS_BUNDLE_FORMAT,
    boot_id: clock.boot_id,
    boottime_ns: clock.boottime_ns,
    wall_ns: clock.wall_ns,
    generation_id: collected.boot.generation_id,
    boot_serial: collected.boot.boot_serial,
    failed_generation: collected.boot.failed_generation,
    redaction: "default",
    caps: {
      events_bytes: MAX_EVENT_BYTES,
      event_lines: MAX_EVENT_LINES,
      report_bytes: MAX_REPORT_BYTES,
      bundle_bytes: MAX_BUNDLE_BYTES,
      store_bytes: MAX_STORE_BYTES,
    },
    files: manifest_files |> sort-by .name |> collect,
    omitted,
  }
  match diagnostics_replace(fp"{staging}/manifest.json", json.encode(manifest, pretty: true)? + "\n") {
    Ok(_) => {}
    Err(problem) => { degraded += [f"manifest:{problem.errno ?? -1}"] }
  }

  let final_entries = [entry.name for entry in fs.files(staging, hidden: true)? if entry.kind == "file"]
  next.remove()
  match archive.create(next, staging, [p"."], .Tar, compression: .Gzip, collision: .Replace) {
    Ok(_) => {}
    Err(_) => {
      next.remove()
      staging.remove()
      degraded += ["archive:instant"]
      return Ok({path: bundle, bytes: 0, sha256: "", files: [], omitted, degraded, secret_present: false})
    }
  }
  let size = next.metadata()?.size
  if size > MAX_BUNDLE_BYTES {
    next.remove()
    staging.remove()
    degraded += ["archive:oversize"]
    return Ok({path: bundle, bytes: 0, sha256: "", files: [], omitted, degraded, secret_present: false})
  }
  let digest = hash.sha256(next)?.hex()
  match next.rename(to: bundle, overwrite: true) {
    Ok(_) => {}
    Err(problem) => {
      next.remove()
      staging.remove()
      degraded += [f"publish:{problem.errno ?? -1}"]
      return Ok({path: bundle, bytes: 0, sha256: "", files: [], omitted, degraded, secret_present: false})
    }
  }
  fs.fsync(bundle)
  fs.fsync(store)
  staging.remove()
  Ok({path: bundle, bytes: size, sha256: digest, files: final_entries |> sort, omitted, degraded, secret_present: false})
}

## Read the canary used only to prove the bundle excludes a known secret.
export proc diagnostics_canary(path_value: Str) [fs, error] -> Result[Str, Error] {
  return Ok("") when path_value == ""
  let file = fp"{path_value}"
  return Ok("") unless file.exists()
  Ok(file.read_text()?.trim())
}

## The maintained guest clock reading.
export proc diagnostics_clock() [fs, time, error] -> Result[DiagnosticClock, Error] {
  let boot_id = p"/proc/sys/kernel/random/boot_id".read_text()?.trim()
  Ok({boot_id, boottime_ns: time.boottime()?, wall_ns: time.now()})
}

proc diagnostics_console(text: Str) {
  p"/dev/console".write(text + "\n")
}

type Options = {help: Bool, phase: Str, store: Str, canary: Str}

## Collect, persist, and publish one diagnostics support bundle.
export proc main(...argv: List[Str]) [fs, process, net, time, env, error] {
  let opts: Options = cli.applet(argv, {
    gnu: {status: 1},
    help: {form: "--help", default: false, stop: true},
    phase: {form: "--phase NAME", default: "boot"},
    store: {form: "--store DIR", default: ""},
    canary: {form: "--canary PATH", default: ""},
  })?
  if opts.help {
    print "usage: diagnostics [--phase NAME] [--store DIR] [--canary PATH]"
    return
  }
  let store = if opts.store == "" { DEFAULT_STORE } else { fp"{opts.store}" }
  let clock = diagnostics_clock()?
  let cmdline = p"/proc/cmdline".read_text()?.split(" ")
  let collected = diagnostics_collect(store, diagnostics_sources(), clock, cmdline)?
  let canary = diagnostics_canary(opts.canary)?
  let {boot: {generation_id: generation, boot_serial: serial, failed_generation: failed, ..}, ..} = collected
  let service_text = collected.services |> map f"{.name}={.state}" |> collect |> join(",")
  diagnostics_console(f"LAPUTA_DIAGNOSTICS_BOOT phase={opts.phase} generation={generation} serial={serial} failed={failed} boot_id={clock.boot_id} boottime_ns={clock.boottime_ns} wall_ns={clock.wall_ns} services={service_text} markers={collected.history.len()}")
  diagnostics_console(f"LAPUTA_DIAGNOSTICS_PERSISTED phase={opts.phase} existing={collected.existing} appended={collected.appended} total={collected.total} bytes={collected.bytes}")
  if ! collected.degraded.is_empty() {
    diagnostics_console(f"LAPUTA_DIAGNOSTICS_DEGRADED phase={opts.phase} reasons={collected.degraded.join(",")} preserved=1")
  }
  let persisted_history = collected.history |> map f"{.generation_id}/{.boot_serial}/{.failed_generation}" |> collect |> join(",")
  let latest_failed = if collected.history.is_empty() { "" } else { collected.history[-1].failed_generation }
  diagnostics_console(f"LAPUTA_DIAGNOSTICS_HISTORY phase={opts.phase} markers={collected.history.len()} entries={persisted_history} failed={latest_failed}")
  let store_bytes = diagnostics_store_bytes(store)?
  let bound_ok = store_bytes <= MAX_STORE_BYTES
  diagnostics_console(f"LAPUTA_DIAGNOSTICS_BOUND phase={opts.phase} bytes={store_bytes} max={MAX_STORE_BYTES} ok={bound_ok}")

  let bundle = diagnostics_bundle(store, [p"/usr/bin/system-report".display(), "system-report"], diagnostics_sections(), clock, collected, canary)?
  if bundle.secret_present {
    diagnostics_console(f"LAPUTA_DIAGNOSTICS_SECRET_PRESENT phase={opts.phase}")
  } else {
    diagnostics_console(f"LAPUTA_DIAGNOSTICS_SECRET_ABSENT phase={opts.phase}")
  }
  if bundle.bytes > 0 {
    diagnostics_console(f"LAPUTA_DIAGNOSTICS_BUNDLE phase={opts.phase} bytes={bundle.bytes} sha256={bundle.sha256} omitted={bundle.omitted.join(",")}")
  } else {
    let preserved = if fp"{store}/{BUNDLE_NAME}".exists() { fp"{store}/{BUNDLE_NAME}".metadata()?.size } else { 0 }
    diagnostics_console(f"LAPUTA_DIAGNOSTICS_BUNDLE_FAILED phase={opts.phase} reasons={bundle.degraded.join(",")} preserved={preserved}")
  }
  diagnostics_console(f"LAPUTA_DIAGNOSTICS_DONE phase={opts.phase}")
  if bundle.secret_present {
    fail "diagnostics bundle contains the canary secret"
  }
}
