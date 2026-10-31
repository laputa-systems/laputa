##! Controller and deployment measurements against the pyinfra oracle.

use xinfra.inventory as inventory
use xinfra.plan as plan
use xinfra.transport as transport
use xinfra.validate as validate

type Fixture = {host: Str, port: Int, username: Str, key: Path, host_key: Str}

type Measure = {ms: Int, rss_mib: Int, connections: Int}

proc required(name: Str) [env, error] -> Result[Str, Error] {
  match env.get(name) {
    Ok(value) => Ok(value),
    Err(error) => Err(error.failure(f"missing {name}: {error.message}")),
  }
}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Error] {
  let host = required(f"XINFRA_FIXTURE_{suffix}_HOST")?
  let port_text = required(f"XINFRA_FIXTURE_{suffix}_PORT")?
  let port = match port_text.parse_int() {
    Ok(value) => value,
    Err(error) => { return Err(error) },
  }
  let username = required("XINFRA_FIXTURE_USER")?
  let key_text = required("XINFRA_FIXTURE_KEY")?
  let host_key = required(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?
  Ok({host: host, port: port, username: username, key: fp"{key_text}", host_key: host_key})
}

proc require(condition: Bool, message: Str) -> Result[Unit, Error] {
  if condition { Ok() } else { Err(error.failure(message)) }
}

proc connect(entry: Fixture) -> Result[transport.Session, Error] {
  match transport.connect_endpoint(entry.host, entry.port, entry.username, entry.key, entry.host_key) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

proc execute(session: transport.Session, argv: List[Str]) -> Result[transport.ExecResult, Error] {
  match transport.exec(session, argv) {
    Ok(value) => Ok(value),
    Err(message) => Err(error.failure(message)),
  }
}

proc reset(session: transport.Session, elevate: List[Str]) -> Result[Unit, Error] {
  let _ = execute(session, [@elevate, "rc-service", "crond", "stop"])?
  let _ = execute(session, [@elevate, "rc-update", "del", "crond", "default"])?
  let _ = execute(session, [@elevate, "userdel", "xinfra-q1-user"])?
  let _ = execute(session, [@elevate, "groupdel", "xinfra-q1-group"])?
  let _ = execute(session, [@elevate, "apk", "del", "tree"])?
  let _ = execute(session, [@elevate, "rm", "-rf", "/home/xinfra/xinfra-q1"])?
  let created = execute(session, [@elevate, "mkdir", "-p", "/home/xinfra/xinfra-q1"])?
  require(created.exit_code == 0, "cannot create performance base")?
  let owned = execute(session, [@elevate, "chown", "xinfra:xinfra", "/home/xinfra/xinfra-q1"])?
  require(owned.exit_code == 0, "cannot own performance base")?
  Ok()
}

proc accepted(session: transport.Session, elevate: List[Str]) -> Result[Int, Error] {
  let result = execute(session, [@elevate, "sh", "-c", "grep -v -e 'ran command' -e 'COMMAND=' /var/log/messages | grep -c 'Accepted publickey' || true"])?
  let value = (result.stdout.utf8() ?? "0").trim().lines().get(0) ?? "0"
  Ok(value.parse_int() ?? 0)
}

proc median(values: List[Int]) -> Int {
  let ordered = values |> sort() |> collect()
  if ordered.is_empty() {
    return 0
  }
  let middle = ordered.len() / 2
  if ordered.len() % 2 == 0 {
    return (ordered[middle - 1] + ordered[middle]) / 2
  }
  ordered[middle]
}

proc rss_mib(output: Str, os_name: Str) -> Int {
  for line in output.lines() {
    if "maximum resident set size" in line {
      for field in line.fields() {
        match field.parse_int() {
          Ok(value) => {
            if value > 1000 {
              if os_name == "Darwin" {
                return value / 1048576
              }
              return value / 1024
            }
          }
          Err(_) => {}
        }
      }
    }
  }
  0
}

proc startup_ms(xsh: Path, root: Path, count: Int) -> Result[Int, Error] {
  var samples: List[Int] = []
  for _ in range(count) {
    let started = time.monotonic()?
    let result = run.capture --text $xsh bin/xinfra.xsh --version
    let elapsed = (time.monotonic()? - started) / 1000000
    require(result.status.ok, "xinfra --version failed")?
    samples += [elapsed]
  }
  Ok(median(samples))
}

proc pyinfra_startup_ms(pyinfra: Path, count: Int) -> Result[Int, Error] {
  var samples: List[Int] = []
  for _ in range(count) {
    let started = time.monotonic()?
    let result = run.capture --text $pyinfra --version
    let elapsed = (time.monotonic()? - started) / 1000000
    require(result.status.ok, "pyinfra --version failed")?
    samples += [elapsed]
  }
  Ok(median(samples))
}

proc xinfra_apply(
  xsh: Path,
  inventory_file: Path,
  deploy_file: Path,
  session: transport.Session,
  elevate: List[Str],
  os_name: Str,
) -> Result[Measure, Error] {
  let before = accepted(session, elevate)?
  let started = time.monotonic()?
  let result = run.capture --text /usr/bin/time -l $xsh bin/xinfra.xsh apply --inventory $inventory_file --deploy $deploy_file --format json
  let elapsed = (time.monotonic()? - started) / 1000000
  let after = accepted(session, elevate)?
  require(result.status.ok, f"xinfra apply failed: {result.stderr.trim()}")?
  Ok(Measure(ms: elapsed, rss_mib: rss_mib(result.stderr, os_name), connections: after - before))
}

proc pyinfra_apply(
  pyinfra: Path,
  home: Path,
  entry: Fixture,
  session: transport.Session,
  elevate: List[Str],
  os_name: Str,
) -> Result[Measure, Error] {
  let before = accepted(session, elevate)?
  let started = time.monotonic()?
  let result = env ({
    HOME: home,
    Q1_HOST: entry.host,
    Q1_PORT: f"{entry.port}",
    Q1_USER: entry.username,
    Q1_KEY: entry.key,
  }) {
    run.capture --text /usr/bin/time -l $pyinfra -y --sudo --serial --limit q1 dev/oracle/inventory.py dev/oracle/deploy.py
  }?
  let elapsed = (time.monotonic()? - started) / 1000000
  let after = accepted(session, elevate)?
  require(result.status.ok, f"pyinfra apply failed: {result.stderr.trim()}")?
  Ok(Measure(ms: elapsed, rss_mib: rss_mib(result.stderr, os_name), connections: after - before))
}

proc handshake_ms(entry: Fixture, count: Int) -> Result[Int, Error] {
  var samples: List[Int] = []
  for _ in range(count) {
    let started = time.monotonic()?
    with session = connect(entry)? {
      let _ = session.token
    }
    samples += [(time.monotonic()? - started) / 1000000]
  }
  Ok(median(samples))
}

proc round_trip_ms(entry: Fixture, count: Int) -> Result[Int, Error] {
  with session = connect(entry)? {
    var samples: List[Int] = []
    for _ in range(count) {
      let started = time.monotonic()?
      let _ = execute(session, ["true"])?
      samples += [(time.monotonic()? - started) / 1000000]
    }
    median(samples)
  }
}

proc local_plan_ms(inventory_file: Path, deploy_file: Path, root: Path) -> Result[Int, Error] {
  var samples: List[Int] = []
  for _ in range(5) {
    let started = time.monotonic()?
    let loaded = match inventory.load(inventory_file) {
      Ok(value) => value,
      Err(error) => { return Err(error) },
    }
    let deployment = match validate.load(deploy_file, loaded, root) {
      Ok(value) => value,
      Err(problem) => { return Err(error.failure(f"{problem.kind}: {problem.message}")) },
    }
    let names = loaded.hosts |> map .name
    let _ = plan.plan(deployment, loaded, plan.empty_facts(names))
    samples += [(time.monotonic()? - started) / 1000000]
  }
  Ok(median(samples))
}

proc make_inventory(
  root: Path,
  entry: Fixture,
) [fs, error] -> Result[Path, Error] {
  let directory = fp"{root}/.work/tmp/perf"
  directory.mkdir(parents: true)?
  let key = fp"{directory}/key"
  entry.key.copy(to: key, overwrite: true)?
  key.chmod(0o600)?
  let inventory_file = fp"{directory}/inventory.toml"
  let text = f"""groups = ["perf"]

[[hosts]]
name = "xinfra-{entry.port}"
groups = ["perf"]
address = "{entry.host}"
port = {entry.port}
user = "{entry.username}"
key = "key"
host_key = "{entry.host_key}"
"""
  inventory_file.write(text)?
  Ok(inventory_file)
}

## Run the performance measurements.
export proc measure() [fs, process, env, time, error, io] -> Result[Unit, Error] {
  let root = fs.gitroot()?
  let a = fixture("A")?
  let b = fixture("B")?
  let xsh = fp"{env.get("XINFRA_XSH") ?? f"{root}/../../xsh/target/aarch64-apple-darwin/release/xsh"}"
  let pyinfra = fp"{env.get("XINFRA_PYINFRA") ?? f"{root}/.work/oracle/venv/bin/pyinfra"}"
  let home = fp"{root}/.work/oracle/home"
  fp"{home}/.ssh".mkdir(parents: true)?
  let inventory_file = make_inventory(root, b)?
  let deploy_file = fp"{root}/dev/perf/deploy.xsh"
  let os_result = run.capture --text uname -s
  let os_name = os_result.stdout.trim()

  let gate_start = run.capture --text perf-gate-ready -s
  print f"perf-gate-ready -s: {gate_start.stdout.trim()}"
  if ! gate_start.status.ok {
    print "perf gate deferred: host busy"
  }

  let startup = startup_ms(xsh, root, 5)?
  let pyinfra_startup = pyinfra_startup_ms(pyinfra, 5)?
  let handshake = handshake_ms(b, 5)?
  let round_trip = round_trip_ms(b, 5)?
  let local_plan = local_plan_ms(inventory_file, deploy_file, root)?

  let version_rss = run.capture --text /usr/bin/time -l $xsh bin/xinfra.xsh --version
  let pyinfra_rss = run.capture --text /usr/bin/time -l $pyinfra --version

  with b_session = connect(b)? {
    reset(b_session, ["doas", "-n"])?
    let first = xinfra_apply(xsh, inventory_file, deploy_file, b_session, ["doas", "-n"], os_name)?
    let no_op = xinfra_apply(xsh, inventory_file, deploy_file, b_session, ["doas", "-n"], os_name)?
    print f"xinfra first: {first.ms} ms, {first.rss_mib} MiB, {first.connections} connections"
    print f"xinfra no-op: {no_op.ms} ms, {no_op.rss_mib} MiB, {no_op.connections} connections"
  }

  with a_session = connect(a)? {
    reset(a_session, ["sudo", "-n"])?
    let first = pyinfra_apply(pyinfra, home, a, a_session, ["sudo", "-n"], os_name)?
    let no_op = pyinfra_apply(pyinfra, home, a, a_session, ["sudo", "-n"], os_name)?
    print f"pyinfra first: {first.ms} ms, {first.rss_mib} MiB, {first.connections} connections"
    print f"pyinfra no-op: {no_op.ms} ms, {no_op.rss_mib} MiB, {no_op.connections} connections"
  }

  print f"xinfra startup: {startup} ms, {rss_mib(version_rss.stderr, os_name)} MiB"
  print f"pyinfra startup: {pyinfra_startup} ms, {rss_mib(pyinfra_rss.stderr, os_name)} MiB"
  print f"handshake: {handshake} ms"
  print f"round trip: {round_trip} ms"
  print f"local plan: {local_plan} ms"

  let gate_end = run.capture --text perf-gate-ready -1
  print f"perf-gate-ready -1: {gate_end.stdout.trim()}"
  Ok()
}

measure()?
