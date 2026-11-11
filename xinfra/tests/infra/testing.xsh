##! Helpers shared by tests and fixtures: local hosts and the disposable
##! Alpine hosts a fixture run publishes in `XINFRA_TEST_INVENTORY`.

use infra.inventory
use infra.model
use infra.report
use infra.transport

## A local host whose privilege is plain, for tests that run scripts on the
## machine running the tests.
export pure local_host(name: Str = "local") -> model.Host {
  model.Host(
    name:,
    transport: .Local,
    dialect: .Posix,
    address: "localhost",
    port: 0,
    user: "local",
    key: null,
    host_key: null,
    privilege: .Plain,
    groups: [],
    vars: {},
    timeout_ms: 20000,
    transfer_timeout_ms: 600000,
    escalate_reads: false,
  )
}

## A local host that runs catalogue scripts as XSH source through the `xsh` on
## PATH, for tests of the xsh dialect.
export pure local_xsh_host(name: Str = "local-xsh") -> model.Host {
  model.Host(
    name:,
    transport: .Local,
    dialect: .Xsh,
    address: "localhost",
    port: 0,
    user: "local",
    key: null,
    host_key: null,
    privilege: .Plain,
    groups: [],
    vars: {},
    timeout_ms: 20000,
    transfer_timeout_ms: 600000,
    escalate_reads: false,
  )
}

## The disposable hosts a fixture run published, or none when no fixture
## environment is present.
export proc fixture_hosts() [env, fs, error] -> Result[List[model.Host], Error] {
  match env.get("XINFRA_TEST_INVENTORY") {
    Err(_) => Ok([])
    Ok(file) => Ok(inventory.load(fp"{file}")?.hosts)
  }
}

## One fixture host by inventory name, or null when no fixture environment is
## present.
export proc fixture_host(name: Str) [env, fs, error] -> Result[model.Host?, Error] {
  let hosts = fixture_hosts()?
  let matching = hosts |> where { |host| host.name == name } |> collect()
  if matching.is_empty() { null } else { matching[0] }
}

## Look up one entry of a report by host and resource id.
export pure entry_of(result: report.Report, host: Str, id: Str) -> report.Entry? {
  let found = result.hosts
    |> where { |item| item.host == host }
    |> flat-map { |item| item.entries }
    |> where { |entry| entry.id == id }
    |> collect()
  if found.is_empty() { null } else { found[0] }
}

## The status of one entry, or `missing` when the report has none.
export pure status_of(result: report.Report, host: Str, id: Str) -> Str {
  let found = entry_of(result, host, id)
  if found == null { "missing" } else { found.status }
}

## A unique remote scratch name derived from a test's temporary directory.
export pure scratch_name(dir: Path) -> Str {
  f"xt-{dir.parent().name()}".replace("_", with: "-")
}

## Run a script on a host and return its standard output as text, failing on a
## nonzero status. Used by tests to look at a fixture host directly.
export proc remote_text(host: model.Host, script: Str, args: List[Str] = [], privileged: Bool = false) [fs, env, process, error] -> Result[Str, Error] {
  let connection = transport.connect(host)?
  let execution = transport.exec_script(connection, script, args, privileged:)?
  guard execution.code == 0 else {
    fail f"exit {execution.code}: {execution.stderr.utf8() ?? ""}"
  }

  Ok(execution.stdout.utf8()?)
}
