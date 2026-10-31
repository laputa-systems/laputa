##! Multi-host barriers, failure policy, and cancellation.

use xinfra.scheduler as scheduler
use xinfra.transport as transport

type Fixture = {host: Str, port: Int, username: Str, key: Path, host_key: Str}

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
  if condition { Ok() } else { Err(message) }
}

proc connect(fixture: Fixture) [error] -> Result[transport.Session, Str] {
  transport.connect_endpoint(fixture.host, fixture.port, fixture.username, fixture.key, fixture.host_key)
}

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Str] {
  transport.exec(session, argv)
}

pure ok_outcomes(results: List[scheduler.OpResult]) -> Bool {
  results |> all { |result| result.outcome == "ok" }
}

pure test_case(label: Str) -> Str {
  f"ok {label}"
}

## Executes the multi-host matrix.
export proc check_multi_host() [fs, process, env, time, error, io] -> Result[Unit, Str] {
  let a = fixture("A")?
  let b = fixture("B")?

  let first = connect(a)?
  let second = connect(b)?
  let hosts = [
    scheduler.HostContext(name: "xinfra-a", session: first),
    scheduler.HostContext(name: "xinfra-b", session: second),
  ]

  let barrier_commands = [
    "printf 1 > /tmp/r6-bar",
    "test -f /tmp/r6-bar",
    "printf done > /tmp/r6-bar2",
  ]
  let barrier = scheduler.run_batch(hosts, barrier_commands, 2, "isolate")?
  require(barrier.len() == 6, "barrier did not run all stages on all hosts")?
  require(ok_outcomes(barrier), "barrier stage failed")?
  print test_case("barrier stages")

  let fail_a = "case \"$(hostname)\" in *xinfra-a) exit 1;; esac"
  let write_second = "printf second > /tmp/r6-second"
  for host in hosts {
    let _ = execute(host.session, ["rm", "-f", "/tmp/r6-second"])?
  }

  let isolated = scheduler.run_batch(hosts, [fail_a, write_second], 2, "isolate")?
  require(isolated.len() == 3, "isolate did not stop only the failed host")?
  let a_second = execute(first, ["test", "-f", "/tmp/r6-second"])?
  let b_second = execute(second, ["test", "-f", "/tmp/r6-second"])?
  require(a_second.exit_code != 0, "failed host continued under isolate")?
  require(b_second.exit_code == 0, "healthy host stopped under isolate")?
  print test_case("isolate keeps healthy hosts")

  for host in hosts {
    let _ = execute(host.session, ["rm", "-f", "/tmp/r6-second"])?
  }
  let aborted = scheduler.run_batch(hosts, [fail_a, write_second], 2, "abort")?
  require(aborted.len() == 2, "abort scheduled a later stage")?
  let aborted_a = execute(first, ["test", "-f", "/tmp/r6-second"])?
  require(aborted_a.exit_code != 0, "abort ran a later stage")?
  print test_case("abort stops new work")

  for host in hosts {
    let _ = execute(host.session, ["rm", "-f", "/tmp/r6-second"])?
  }
  let continued = scheduler.run_batch(hosts, [fail_a, write_second], 2, "continue")?
  require(continued.len() == 4, "continue did not run the later stage")?
  print test_case("continue keeps independent work")

  let start = time.now()
  let _ = scheduler.run_batch(hosts, ["sleep 1"], 2, "isolate")?
  let parallel_ms = time.now() - start
  let start_serial = time.now()
  let _ = scheduler.run_batch(hosts, ["sleep 1"], 1, "isolate")?
  let serial_ms = time.now() - start_serial
  require(parallel_ms < 1800, f"jobs=2 was not concurrent: {parallel_ms}ms")?
  require(serial_ms >= 1800, f"jobs=1 was not serial: {serial_ms}ms")?
  print test_case("bounded host concurrency")

  let timed = scheduler.run_batch(hosts, ["sleep 5"], 2, "isolate", 200)?
  require(timed.len() == 2, "timeout retried a submitted command")?
  require((timed |> where { |result| result.outcome == "unknown" } |> count()) == 2, "timeout was not unknown")?
  print test_case("timeout is unknown and not retried")

  for host in hosts {
    let _ = execute(host.session, ["rm", "-f", "/tmp/r6-bar", "/tmp/r6-bar2"])?
  }
  Ok()
}
