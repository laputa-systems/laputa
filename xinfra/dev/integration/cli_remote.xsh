##! CLI remote apply concurrency and report checks.

use xinfra.report
use xinfra.transport

type Fixture = {host: Str, port: Int, user: Str, key: Path, pin: Str}

proc fixture(suffix: Str) [env, error] -> Result[Fixture, Error] {
  let port = env.get(f"XINFRA_FIXTURE_{suffix}_PORT")?.parse_int()?
  Ok(Fixture(host: env.get(f"XINFRA_FIXTURE_{suffix}_HOST")?, port: port, user: env.get("XINFRA_FIXTURE_USER")?, key: fp"{env.get("XINFRA_FIXTURE_KEY")?}", pin: env.get(f"XINFRA_FIXTURE_{suffix}_HOST_KEY")?))
}

proc require(condition: Bool, message: Str) -> Result[Unit, Error] {
  if condition { Ok() } else { Err(error.failure(message)) }
}

proc connect(entry: Fixture) -> Result[transport.Session, Error] {
  match transport.connect_endpoint(entry.host, entry.port, entry.user, entry.key, entry.pin) {
    Ok(value) => Ok(value), Err(message) => Err(error.failure(message)),
  }
}

proc remote(session: transport.Session, argv: List[Str]) -> Result[Int, Error] {
  match transport.exec(session, argv) {
    Ok(value) => Ok(value.exit_code), Err(message) => Err(error.failure(message)),
  }
}

proc wait_for(session: transport.Session, target: Str) [time, error] -> Result[Unit, Error] {
  for _ in range(300) {
    if remote(session, ["test", "-f", target])? == 0 { return Ok() }
    time.sleep(100ms)?
  }
  Err(error.failure(f"timed out waiting for {target}"))
}

proc coordinate(a: transport.Session, b: transport.Session, barrier_dir: Str, jobs: Int) [time, error] -> Result[Unit, Error] {
  defer {
    let _ = remote(a, ["touch", f"{barrier_dir}/release"])
    let _ = remote(b, ["touch", f"{barrier_dir}/release"])
  }
  wait_for(a, f"{barrier_dir}/started")?
  if jobs == 2 {
    wait_for(b, f"{barrier_dir}/started")?
    require(remote(a, ["test", "-d", "/run/xinfra.lock"])? == 0, "first lock missing during apply")?
    require(remote(b, ["test", "-d", "/run/xinfra.lock"])? == 0, "second lock missing during apply")?
    let _ = remote(b, ["touch", f"{barrier_dir}/release"])?
  } else {
    for _ in range(10) {
      require(remote(b, ["test", "-f", f"{barrier_dir}/started"])? != 0, "second host started before first was released")?
    }
  }
  let _ = remote(a, ["touch", f"{barrier_dir}/release"])?
  if jobs == 1 {
    wait_for(b, f"{barrier_dir}/started")?
    let _ = remote(b, ["touch", f"{barrier_dir}/release"])?
  }
  Ok()
}

proc run_case(xsh: Path, inventory: Path, deployment: Path, a: transport.Session, b: transport.Session, barrier_dir: Str, jobs: Int) [fs, process, time, error, io] -> Result[Unit, Error] {
  defer {
    for session in [a, b] {
      let _ = remote(session, ["rm", "-rf", barrier_dir])
    }
  }
  for session in [a, b] {
    require(remote(session, ["mkdir", "-p", barrier_dir])? == 0, "cannot prepare barrier")?
  }
  let results = [0, 1] |> par-map(jobs: 2) { |worker|
    if worker == 0 {
      let result = run.capture --text $xsh bin/xinfra.xsh apply --inventory $inventory --deploy $deployment --jobs $jobs --format json
      if result.status.ok { result.stdout } else { "ERROR: " + result.stderr }
    } else {
      match coordinate(a, b, barrier_dir, jobs) { Ok(_) => "", Err(failure) => "ERROR: " + failure.message }
    }
  }
  require(results[1] == "", results[1])?
  require(! results[0].starts_with("ERROR:"), results[0])?
  let decoded = json.decode(results[0])?.require(report.Report)?
  require(decoded.results.len() == 2, "expected exactly one row per host action")?
  require(decoded.summary.changed == 2 and decoded.summary.exit == 0, "apply did not succeed on both hosts")?
  for name in ["xinfra-a", "xinfra-b"] {
    require((decoded.results |> where { |row| row.host == name and row.resource == "barrier" } |> count()) == 1, f"missing or duplicate row for {name}")?
  }
  for session in [a, b] {
    require(remote(session, ["test", "-d", "/run/xinfra.lock"])? != 0, "lock remained after apply")?
  }
  Ok()
}

## Exercises the CLI against both SSH fixtures.
export proc check_cli_remote() [fs, process, env, time, error, io] -> Result[Unit, Error] {
  let a = fixture("A")?
  let b = fixture("B")?
  let root = fs.gitroot()?
  let xsh = fp"{env.get("XINFRA_XSH")?}"
  let dir = fp"{root}/.work/tmp/cli-remote-{time.now()}"
  dir.mkdir(parents: true)?
  defer { let _ = dir.remove(missing_ok: true) }
  let key = fp"{dir}/key"
  a.key.copy(to: key, overwrite: true)?
  key.chmod(0o600)?
  let inventory = fp"{dir}/inventory.toml"
  inventory.write(f"""groups = ["test"]
[[hosts]]
name = "xinfra-a"
groups = ["test"]
address = "{a.host}"
port = {a.port}
user = "{a.user}"
key = "key"
host_key = "{a.pin}"
[[hosts]]
name = "xinfra-b"
groups = ["test"]
address = "{b.host}"
port = {b.port}
user = "{b.user}"
key = "key"
host_key = "{b.pin}"
""")?
  with first = connect(a)? {
    with second = connect(b)? {
      for jobs in [2, 1] {
        let barrier_dir = f"/tmp/xinfra-cli-{time.now()}-{jobs}"
        let deployment = fp"{dir}/deploy.xsh"
        deployment.write(f"""##! CLI integration deployment.
use xinfra.model
## Returns resources.
export pure resources() -> List[model.Resource] {{
  [model.CommandResource(model.CommandSpec(id: "barrier", shell: "touch {barrier_dir}/started; n=0; while [ ! -f {barrier_dir}/release ]; do n=$((n+1)); [ $n -lt 60 ] || exit 1; sleep 1; done", always_run: true))]
}}
""")?
        run_case(xsh, inventory, deployment, first, second, barrier_dir, jobs)?
      }
    }
  }
  print "ok CLI remote apply concurrency and reports"
  Ok()
}
