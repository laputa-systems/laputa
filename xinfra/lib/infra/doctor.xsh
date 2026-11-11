##! Validate a host before anything is declared against it: the connection and
##! pinned key, the remote shell contract, the utility baseline, the authority
##! policy and the lock. Read-only.

use infra.lock
use infra.model
use infra.observe
use infra.probe
use infra.report
use infra.scripts
use infra.transport

const required = ["stat", "sha256sum", "od", "tr", "mktemp", "mv", "readlink", "chmod", "chown", "ln", "rm", "mkdir", "rmdir", "cat", "awk", "id", "sed", "wc", "head"]

const resource_tools = [
  ["package", "apk"],
  ["service", "rc-service"],
  ["service", "rc-update"],
  ["user", "adduser"],
  ["user", "deluser"],
  ["group", "addgroup"],
  ["group", "delgroup"],
]

const hostile = ["plain", "", "-x", "it's", "a b", "line\nbreak", "$HOME", "$(echo injected)", "`id`", "; id", "\\", "caf\u{e9}"]

pure check(host: Str, id: Str, ok: Bool, detail: Str) -> report.Entry {
  report.Entry(
    host:,
    id:,
    kind: "check",
    status: if ok { "satisfied" } else { "failed" },
    act: null,
    changes: [],
    conditional: false,
    phase: null,
    detail: if detail == "" { null } else { report.sanitize(detail) },
    verified: null,
  )
}

pure note(host: Str, id: Str, detail: Str) -> report.Entry {
  report.Entry(
    host:,
    id:,
    kind: "check",
    status: "not-evaluated",
    act: null,
    changes: [],
    conditional: false,
    phase: null,
    detail: report.sanitize(detail),
    verified: null,
  )
}

## Which declared resource kinds the host's tools cannot support.
export pure unsupported(absent: List[Str]) -> List[Str] {
  var kinds: List[Str] = []
  for pair in resource_tools {
    if pair[1] in absent and pair[0] not in kinds {
      kinds += [pair[0]]
    }
  }

  kinds
}

## The baseline utilities missing from a capability report.
export pure missing_required(absent: List[Str]) -> List[Str] {
  required |> where { |tool| tool in absent } |> collect()
}

proc shell_contract(connection: transport.Connection, host: Str) [process, error] -> report.Entry {
  match transport.exec(connection, scripts.echo_arguments, hostile) {
    Err(error) => check(host, "shell", false, error.message)
    Ok(execution) => {
      let expected = hostile |> map { |word| word + "\0" } |> collect()
      let seen = execution.stdout.utf8() ?? ""
      if execution.code == 0 and seen == expected.join("") {
        check(host, "shell", true, "POSIX quoting round trip")
      } else {
        check(host, "shell", false, "the remote shell did not return hostile arguments unchanged; it must accept POSIX single quotes")
      }
    }
  }
}

proc authority(connection: transport.Connection, host: model.Host, capabilities: probe.Capabilities) [process, error] -> report.Entry {
  match host.privilege {
    model.Plain => check(host.name, "privilege", true, f"plain: mutations run as uid {capabilities.uid}")
    model.Root => check(host.name, "privilege", capabilities.uid == 0, f"root: the login runs as uid {capabilities.uid}")
    model.Doas => {
      match transport.exec(connection, "id -u", privileged: true) {
        Err(error) => check(host.name, "privilege", false, error.message)
        Ok(execution) => {
          let uid = (execution.stdout.utf8() ?? "").trim()
          check(host.name, "privilege", execution.code == 0 and uid == "0", f"doas -n: exit {execution.code}, uid {uid}")
        }
      }
    }
  }
}

proc inspect_host(host: model.Host, lock_path: Str) [env, process, error] -> report.HostReport {
  let connection = match transport.connect(host) {
    Ok(opened) => opened
    Err(error) => {
      return report.HostReport(host: host.name, ok: false, phase: "connect", detail: report.sanitize(error.message), entries: [])
    }
  }

  var entries = [check(host.name, "connect", true, f"{host.user}@{host.address}:{host.port}")]
  entries += [shell_contract(connection, host.name)]
  match observe.capabilities(connection) {
    Err(error) => {
      entries += [check(host.name, "utilities", false, error.message)]
    }
    Ok(found) => {
      let lacking = missing_required(found.absent)
      entries += [check(host.name, "utilities", lacking.is_empty(), if lacking.is_empty() { "baseline present" } else { f"missing: {lacking.join(", ")}" })]
      for kind in unsupported(found.absent) {
        entries += [note(host.name, f"support-{kind}", f"{kind} resources are unsupported on this host")]
      }

      entries += [authority(connection, host, found)]
    }
  }

  let target = lock_path.replace("{host}", with: host.name)
  match lock.inspect(connection, target) {
    Err(error) => {
      entries += [check(host.name, "lock", false, error.message)]
    }
    Ok(holder) => {
      entries += [check(host.name, "lock", holder == null, if holder == null { "free" } else { f"held: {holder}" })]
    }
  }

  let _ = transport.disconnect(connection)
  let ok = entries |> all { |entry| entry.status != "failed" }
  report.HostReport(host: host.name, ok:, phase: null, detail: null, entries:)
}

## Inspect each host and report every check. Nothing is changed.
export proc inspect(hosts: List[model.Host], lock_path: Str, jobs: Int) [env, process, error] -> report.Report {
  let reports = hosts |> par-map(jobs:) { |host| inspect_host(host, lock_path) } |> collect()
  report.Report(mode: "doctor", hosts: reports)
}
