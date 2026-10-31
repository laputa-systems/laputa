##! Alpine package matrix against the disposable fixtures.

use xinfra.host as host
use xinfra.model as model
use xinfra.plan as plan
use xinfra.resources.package as package
use xinfra.transport as transport

type Fixture = {
  host: Str,
  port: Int,
  username: Str,
  key: Path,
  host_key: Str,
}

proc required(name: Str) [env, error] -> Result[Str, Str] {
  match env.get(name) {
    Ok(value) => Ok(value),
    Err(error) => Err(f"missing {name}: {error.message}"),
  }
}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Str] {
  let host = required(f"XINFRA_FIXTURE_{suffix}_HOST")?
  let port_text = required(f"XINFRA_FIXTURE_{suffix}_PORT")?
  let port = match port_text.parse_int() {
    Ok(value) => value,
    Err(error) => { return Err(error.message) },
  }
  let username = required("XINFRA_FIXTURE_USER")?
  let key_text = required("XINFRA_FIXTURE_KEY")?
  let host_key = required(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?
  Ok({host: host, port: port, username: username, key: fp"{key_text}", host_key: host_key})
}

proc require(condition: Bool, message: Str) -> Result[Unit, Str] {
  if condition {
    Ok()
  } else {
    Err(message)
  }
}

proc connect(fixture: Fixture) [error] -> Result[transport.Session, Str] {
  transport.connect_endpoint(
    fixture.host,
    fixture.port,
    fixture.username,
    fixture.key,
    fixture.host_key,
  )
}

proc run_command(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Str] {
  transport.exec(session, argv)
}

proc fact(session: transport.Session, spec: model.PackageSpec) -> Result[plan.Observed, Str] {
  match package.fact(session, spec) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

proc apply(
  session: transport.Session,
  host_name: Str,
  spec: model.PackageSpec,
  elevate: List[Str],
) -> Result[package.PackageApply, Str] {
  match package.apply_remote(session, host_name, spec, elevate) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.message),
  }
}

pure status_name(status: host.ApplyStatus) -> Str {
  if status == host.Changed { return "changed" }
  if status == host.Unchanged { return "unchanged" }
  if status == host.Failed { return "failed" }
  if status == host.Partial { return "partial" }
  if status == host.Blocked { return "blocked" }
  if status == host.Unknown { return "unknown" }
  "other"
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the package matrix.
export proc check_packages() [fs, process, env, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?

  with session = connect(a)? {
    let elevate = ["sudo", "-n"]
    let _ = run_command(session, [@elevate, "apk", "del", "tree"])?

    let plan_spec = model.PackageSpec(id: "tree", name: "tree")
    let before = fact(session, plan_spec)?
    let assessment = plan.assess(model.Package(plan_spec), null, before)
    require(assessment.prediction == plan.Changed, "plan did not predict the package change")?
    let after = fact(session, plan_spec)?
    require(before == after, "plan mutated the package state")?
    print test_case("plan performs no refresh or install")

    let invalid = model.PackageSpec(id: "tree", name: "tree", constraint: "^bad")
    let rejected = apply(session, a.host, invalid, elevate)?
    require(rejected.result.status == host.Failed, "unsupported constraint was accepted")?
    require(!rejected.refreshed, "unsupported constraint refreshed the index")?
    match fact(session, plan_spec)? {
      plan.Absent => {}
      _ => return Err("unsupported constraint installed the package"),
    }
    print test_case("unsupported constraint fails before mutation")

    let install = model.PackageSpec(id: "tree", name: "tree", refresh_index: true)
    let installed = apply(session, a.host, install, elevate)?
    require(installed.result.status == host.Changed and installed.result.verified, f"install failed: {status_name(installed.result.status)} {installed.result.cause ?? ""}")?
    require(installed.refreshed, "install did not report its index refresh")?
    print test_case("install and refresh reporting")

    let plus = model.PackageSpec(id: "stdcpp", name: "libstdc++")
    match fact(session, plus)? {
      plan.Installed(_) => {}
      _ => { return Err("libstdc++ fact was not installed") },
    }
    let plus_result = apply(session, a.host, plus, elevate)?
    require(plus_result.result.status == host.Unchanged, "libstdc++ was not unchanged")?
    print test_case("package name with plus")

    let version = match fact(session, plan_spec)? {
      plan.Installed(facts) => facts.version ?? "",
      _ => { return Err("installed package is missing") },
    }
    let exact = model.PackageSpec(id: "tree", name: "tree", constraint: f"={version}")
    let exact_result = apply(session, a.host, exact, elevate)?
    require(exact_result.result.status == host.Unchanged, "exact version was not unchanged")?
    let constrained = model.PackageSpec(id: "tree", name: "tree", constraint: ">=2.0")
    let constrained_result = apply(session, a.host, constrained, elevate)?
    require(constrained_result.result.status == host.Unchanged, "satisfied constraint was not unchanged")?
    let prefix = model.PackageSpec(id: "tree", name: "tree", constraint: "~2.2")
    let prefix_result = apply(session, a.host, prefix, elevate)?
    require(prefix_result.result.status == host.Unchanged, "satisfied prefix constraint was not unchanged")?
    print test_case("exact, constrained, and prefix versions")

    let absent = model.PackageSpec(id: "tree", name: "tree", state: model.Absent)
    let removed = apply(session, a.host, absent, elevate)?
    require(removed.result.status == host.Changed and removed.result.verified, "package removal failed")?
    match fact(session, plan_spec)? {
      plan.Absent => {}
      _ => return Err("removed package is still installed"),
    }
    let again = apply(session, a.host, absent, elevate)?
    require(again.result.status == host.Unchanged, "second removal was not unchanged")?
    print test_case("package present and absent")
  }

  Ok()
}
