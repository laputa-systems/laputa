##! Supervises ntpd-rs.
error NtpdStatusError = InvalidStatus(kind: Str, message: Str)

pure restart_policy() -> Record {
  {mode: "always", delay_ms: 1000, max_delay_ms: 30000, stable_after_ms: 10000}
}

## Service declaration.
export let service = {
  name: "ntpd-rs",
  kind: "longrun",
  command: process.command_argv(/usr/bin/xsh, ["/usr/bin/xsh", "/usr/lib/ntpd-rs/launch.xsh"]),
  targets: [
    "boot",
  ],
  dependencies: {
    uses: [
      "net",
    ],
  },
  readiness: "notify",
  ready_timeout_ms: 5000,
  stop_timeout_ms: 2000,
  restart: restart_policy(),
  logging: "append",
}

## Package operation.
export proc status() [fs, process, env, error] -> Result[Str, Error] {
  let ntp_ctl = "/usr/bin/ntp-ctl"
  let administered_config = p"/etc/ntpd-rs/ntp.toml"
  let config = if administered_config.exists()? { administered_config } else { p"/usr/share/ntpd-rs/ntp.toml" }
  let text = run.text $ntp_ctl "status" "-c" f"{config}"

  for line in text.lines() {
    if line.trim().starts_with("Stratum:") {
      return Ok(f"stratum={line.trim().replace("Stratum:", with: "").trim()}")
    }
  }
  Err(NtpdStatusError.InvalidStatus(kind: "ntpd-rs-status", message: "ntp-ctl returned no stratum"))
}
