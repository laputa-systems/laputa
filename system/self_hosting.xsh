##! Running-generation observation for the bounded self-hosting activation loop.
use system.activation

type SelfHostingBootReport = {generation_id: Str, boot_serial: Int, root_digest: Str}

pure self_hosting_parse_boot_report(log: Str, expected: activation.GenerationReceipt, serial: Int) -> Result[Bool, Error] {
  let prefix = "LAPUTA_SELF_HOSTING_ACTIVATION "
  let lines = log.split("\n")
  let reports = lines[..lines.len() - 1] |> where .starts_with(prefix) |> collect
  return false when reports.is_empty()
  guard reports.len() == 1 else { fail "self-hosting boot observation is duplicated" }
  let report = json.decode(reports[0][prefix.count_chars()..].trim())?.require_exact(SelfHostingBootReport)?
  guard report.generation_id == expected.id and report.boot_serial == serial and report.root_digest == expected.root_digest else {
    fail "self-hosting boot observation differs from the selected generation"
  }
  true
}


## Read the raw serial file so log aggregation cannot synthesize a record delimiter.
export proc self_hosting_boot_report_complete(console_log: Path, expected: activation.GenerationReceipt, serial: Int) [fs, error] -> Result[Bool, Error] {
  self_hosting_parse_boot_report(console_log.read_text()?, expected, serial)
}
