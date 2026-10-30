#!/bin/xsh

proc ready() -> Result[Bool] {
  let status = p"/run/xinit/dropbear.json"
  return false unless status.exists()?
  json.get(json.read(status)?, ["state"], "").require(Str)? == "running"
}

## The failed generation the launcher reports on a fallback boot, or empty.
## The id charset is restricted by the activation record, so no quoting is needed.
proc boot_failed_id(words: List[Str]) -> Result[Str, Error] {
  var found = ""
  for word in words {
    if word.starts_with("LAPUTA_FAILED_GENERATION=") and found == "" {
      found = word.replace("LAPUTA_FAILED_GENERATION=", with: "")
    }
  }
  found
}

## Render one boot marker line. Only generation identity, service states, and
## digests enter the marker; secrets never do because no secret file is read.
proc boot_marker_line(id: Str, serial: Int, failed: Str, root_digest: Str, profile: Str, services: List[Record]) -> Result[Str, Error] {
  json.encode({
    format: "laputa-boot-marker-1",
    generation_id: id,
    boot_serial: serial,
    failed_generation: failed,
    root_digest,
    profile,
    services,
  })?
}

## Keep only the newest markers so the log stays bounded across reboots.
proc cap_marker_lines(lines: List[Str], keep: Int) -> List[Str] {
  return lines when lines.len() <= keep
  lines[lines.len() - keep..]
}

proc append_boot_marker(path_value: Path, line: Str) {
  path_value.parent.mkdir()
  var lines: List[Str] = []
  if path_value.exists() {
    lines = path_value.read_text()?.lines() |> where .trim() != "" |> collect
  }
  lines = cap_marker_lines(lines + [line], 20)
  path_value.write_atomic(lines.join("\n") + "\n")
  fs.fsync(path_value)
}

proc main() {
  let cmdline = p"/proc/cmdline".read_text()?.split(" ")
  let ids = cmdline |> where .starts_with("LAPUTA_GENERATION_ID=") |> collect
  let serials = cmdline |> where .starts_with("LAPUTA_BOOT_SERIAL=") |> collect
  return when ids.is_empty() and serials.is_empty()
  guard ids.len() == 1 and serials.len() == 1 else { fail "ambiguous boot selection" }
  let id = ids[0].replace("LAPUTA_GENERATION_ID=", with: "")
  let serial = serials[0].replace("LAPUTA_BOOT_SERIAL=", with: "").trim().parse_int()?
  wait until ready() within 30s every 100ms
  let receipt = json.read(p"/run/laputa-running-generation.json")?
  var services: List[Record] = []
  for item in g"/run/xinit/*.json" {
    let value = json.read(item)?
    let name = json.get(value, ["name"], "").require(Str)?
    if name != "" { services += [{name: name, state: json.get(value, ["state"], "").require(Str)?}] }
  }
  let report = {
    format: "laputa-guest-health-1",
    generation_id: id,
    boot_serial: serial,
    root_digest: json.get(receipt, ["generation_sha256"], "").require(Str)?,
    profile: json.get(receipt, ["profile"], "").require(Str)?,
    services,
  }
  let encoded = json.encode(report)?
  p"/run/laputa-health.json".write(encoded + "\n")
  p"/dev/console".write(f"LAPUTA_ACTIVATION_HEALTH {encoded}\n")
  let failed = boot_failed_id(cmdline)?
  let marker = boot_marker_line(id, serial, failed, report.root_digest, report.profile, services)?
  p"/dev/console".write(f"LAPUTA_BOOT_MARKER {marker}\n")
  let _ = try {
    append_boot_marker(p"/var/log/boot-markers.log", marker)
  }
  if p"/var/log/boot-markers.log".exists() {
    let marker_lines = p"/var/log/boot-markers.log".read_text()?.lines() |> where .trim() != "" |> collect
    p"/dev/console".write(f"LAPUTA_BOOT_MARKER_COUNT {marker_lines.len()}\n")
  }
}
