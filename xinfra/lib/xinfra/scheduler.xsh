##! Bounded multi-host stages with failure policy.

use xinfra.transport as transport

## One host's connection in a multi-host run.
export type HostContext = {name: Str, session: transport.Session}

## One host's result for one operation.
export type OpResult = {host: Str, outcome: Str, detail: Str}

pure valid_policy(policy: Str) -> Bool {
  policy in ["isolate", "abort", "continue"]
}

proc run_one(host: HostContext, command: Str, timeout_ms: Int?) [process, error, io] -> OpResult {
  match transport.exec(host.session, ["sh", "-c", command], timeout_ms) {
    Ok(result) => {
      if result.exit_code == 0 {
        {host: host.name, outcome: "ok", detail: ""}
      } else {
        {
          host: host.name,
          outcome: "failed",
          detail: (result.stderr.utf8() ?? "").trim(),
        }
      }
    }
    Err(message) => {
      {host: host.name, outcome: "unknown", detail: message}
    }
  }
}

## Run each command as a barrier stage over every active host.
export proc run_batch(
  hosts: List[HostContext],
  commands: List[Str],
  jobs: Int = 8,
  policy: Str = "isolate",
  timeout_ms: Int? = null,
) -> Result[List[OpResult], Str] {
  if ! valid_policy(policy) {
    return Err(f"unsupported failure policy {policy}")
  }
  if jobs < 1 or jobs > 64 {
    return Err("jobs must be between 1 and 64")
  }

  var active = hosts
  var results = []
  for command in commands {
    if active.is_empty() {
      break
    }
    let batch = active |> par-map(jobs: jobs) { |host| run_one(host, command, timeout_ms) }
    results += batch
    let failed = batch |> where { |result| result.outcome != "ok" }
    if ! failed.is_empty() {
      if policy == "abort" {
        break
      }
      if policy == "isolate" {
        let failed_hosts = failed |> map .host
        active = active |> where { |host| host.name not in failed_hosts }
      }
    }
  }
  Ok(results)
}
