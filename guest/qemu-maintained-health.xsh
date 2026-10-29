#!/bin/xsh

proc ready() -> Result[Bool] {
  let status = p"/run/xinit/dropbear.json"
  return false unless status.exists()?
  json.get(json.read(status)?, ["state"], "").require(Str)? == "running"
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
}
